#!/usr/bin/env bash
# build-bundle.sh — produce a signed agora-os OTA bundle from pi-gen output.
#
# Companion to assemble.sh. Both scripts must consume the EXACT SAME
# boot.tar + rootfs.tar emitted by a single pi-gen run (D62) — any byte
# difference between freshly-flashed slot A and OTA-applied slot B is a
# class of bug that's painful to debug. release.yml extracts pi-gen
# output once into a working dir and points both scripts at it.
#
# Output format is the bundle spec at sslivins/agora's docs/bundle-format.md:
#   <out>.tar.zst                   ← zstd-compressed 3-entry tarball
#     boot/                         ← exact contents of the boot tarball
#     root/                         ← rootfs minus identity files (D63)
#     meta.json                     ← version, manifest, builder
#   <out>.tar.zst.minisig           ← detached minisign signature
#                                     (signed over post-compression bytes
#                                     so the verifier can reject without
#                                     decompressing)
#
# Identity-strip (D63): /etc/machine-id and /etc/ssh/ssh_host_* are
# removed from root/ before packing. The bundle ships a generic image;
# the apply step on the device re-instates the device's own identity
# files (D60 fleet-state copy) before triggering tryboot.
#
# Usage:
#   build-bundle.sh <rootfs-tar> <boot-tar> <version> <out-bundle.tar.zst>
#
# Signing is performed by release.yml in a separate step using the same
# MINISIGN_SECRET that signs the .img.xz. This script does NOT sign;
# keeping that out of here means a developer can rehearse a bundle build
# locally without needing the secret.

set -euo pipefail

# Must run as root: rootfs.tar contains /dev/* character devices and
# `tar -xf` needs CAP_MKNOD to recreate them. Mirror of assemble.sh's
# root check; without this the extract fails opaquely on the first
# device-node entry. Local rehearsal: `sudo image-build/build-bundle.sh ...`
if [[ $EUID -ne 0 ]]; then
    echo "build-bundle.sh: must run as root (tar -xf needs CAP_MKNOD for /dev/* nodes)." >&2
    exit 1
fi

ROOTFS_TAR="${1:?usage: build-bundle.sh <rootfs-tar> <boot-tar> <version> <out-bundle.tar.zst>}"
BOOT_TAR="${2:?usage: build-bundle.sh <rootfs-tar> <boot-tar> <version> <out-bundle.tar.zst>}"
VERSION="${3:?usage: build-bundle.sh <rootfs-tar> <boot-tar> <version> <out-bundle.tar.zst>}"
OUT_BUNDLE="${4:?usage: build-bundle.sh <rootfs-tar> <boot-tar> <version> <out-bundle.tar.zst>}"

# Belt-and-suspenders v-prefix strip. release.yml passes ${GITHUB_REF_NAME#v}
# so a tag-driven build is already clean, but manual / local rebundles
# routinely pass the raw tag (e.g. "v0.0.7-test"). The device-side
# dispatch validator (pydantic) rejects a meta.json version that starts
# with "v", which produces a hard-to-diagnose "bad signature"-shaped
# error on apply.
VERSION="${VERSION#v}"

# /etc/agora/version contents (F17, Decision #2). Same env-var contract
# as assemble.sh — both scripts run in the same release.yml job so the
# values are always in sync. Without this block, an OTA-applied slot B
# has NO /etc/agora/version at all (the rootfs tarball has only the
# stock pi-gen output; the version file is image-build-time content
# that assemble.sh bakes in for slot A but the bundle producer must
# also bake in for slot B).
: "${AGORA_OS_VERSION:?AGORA_OS_VERSION env var required (e.g. '0.0.4-test'); release.yml sets this from \${GITHUB_REF_NAME#v}}"
: "${AGORA_APP_FLOOR:?AGORA_APP_FLOOR env var required (e.g. '1.11.0'); release.yml sets this from image-build/agora-app-floor.txt}"

# Same v-prefix defense as VERSION above. release.yml already strips,
# but local / manual rebundle invocations regularly forget.
AGORA_OS_VERSION="${AGORA_OS_VERSION#v}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Builder identity — best-effort, falls back to local invocation marker.
BUILDER_REPO="${GITHUB_REPOSITORY:-sslivins/agora-os}"
BUILDER_SHA="${GITHUB_SHA:-$(cd "$HERE" && git rev-parse --short HEAD 2>/dev/null || echo 'local')}"
BUILDER_RUN_ID="${GITHUB_RUN_ID:-local}"
BUILDER="${BUILDER_REPO}@${BUILDER_SHA}+${BUILDER_RUN_ID}"

# Sanity-check inputs early so we fail before doing 5+ minutes of work.
for f in "$ROOTFS_TAR" "$BOOT_TAR"; do
    if [[ ! -f "$f" ]]; then
        echo "build-bundle.sh: input file missing: $f" >&2
        exit 1
    fi
done

# zstd window-log of 27 matches the device-side decompressor build
# (ZSTD_WINDOWLOG_MAX_64=27). Larger windows would refuse to decompress
# on the Pi without rebuilding zstd.
ZSTD_LEVEL=19
ZSTD_WINDOW_LOG=27

# min_from_version: floor that the device's current version must satisfy
# to accept this bundle (Phase 2 #21). We default to "0.0.0" rather than
# empty so meta.json always has a real floor string: the device-side
# bundle verifier (os_updater/bundle.py) treats a NULL/missing
# min_from_version as a hard rejection ("strict-key check"), and any
# semver >= 0.0.0 is automatically every shipped version, so this is a
# no-op floor when the env var isn't set. release.yml overrides per-tag
# when an actual floor is needed.
MIN_FROM_VERSION="${MIN_FROM_VERSION:-0.0.0}"
# Strip optional v-prefix here too, same rationale as VERSION above.
MIN_FROM_VERSION="${MIN_FROM_VERSION#v}"

# Schema version of the bundle layout itself (Phase 2 #22). Bumped when
# we add fields to meta.json, change tarball structure, or change the
# device-side apply contract. v1 of the bundle format = schema 1.
BUNDLE_SCHEMA_VERSION=1

WORK="$(mktemp -d -t agora-bundle.XXXXXX)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "build-bundle: staging in ${WORK}"

# ---------------------------------------------------------------------------
# Step 1: extract boot + rootfs into the bundle layout.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bundle/boot" "${WORK}/bundle/root"

echo "build-bundle: extracting boot tarball..."
tar -xf "$BOOT_TAR" -C "${WORK}/bundle/boot"

echo "build-bundle: extracting rootfs tarball..."
tar -xf "$ROOTFS_TAR" -C "${WORK}/bundle/root"

# ---------------------------------------------------------------------------
# Step 2: apply shared rootfs customizations.
#
# Shared with assemble.sh — same script, same set of installed files,
# same env-var contract (AGORA_OS_VERSION + AGORA_APP_FLOOR).
#
# Pre-refactor (through v0.0.6-test), this script open-coded a much
# smaller subset: identity-strip + /etc/agora/version heredoc. That
# omitted pubkeys, firstboot service, system.conf.d/agora.conf,
# logrotate, timesyncd, /etc/fstab.template, the apply.py mount-point
# dirs (/boot/firmware-b, /mnt/inactive-root), and the EEPROM artifacts.
# The missing fstab.template almost certainly bricked Pi 192.168.1.100
# during the v0.0.6-test manual OTA: apply.py reaches for
# /etc/fstab.template on the new slot to substitute BOOT_PARTLABEL, and
# the new slot didn't have one. Now both producers run the same script.
#
# customize-rootfs.sh does NOT touch /etc/fstab itself (assemble.sh
# writes a per-slot fstab via write_boot_config; apply.py writes a
# per-target-slot fstab from the template at OTA-apply time). It DOES
# install /etc/fstab.template into root/ so apply.py has it to read.
# ---------------------------------------------------------------------------
echo "build-bundle: applying shared rootfs customizations..."
"${HERE}/customize-rootfs.sh" "${WORK}/bundle/root" "${WORK}/bundle/boot"

# Defensive: if the pi-gen rootfs tarball ships a default /etc/fstab,
# remove it. apply.py writes a fresh per-target-slot fstab from the
# template before triggering tryboot. Leaving a pi-gen-default fstab in
# place would race with apply.py and risk the slot booting against the
# wrong PARTLABEL (which is exactly what bricked 192.168.1.100 on
# v0.0.6-test).
rm -f "${WORK}/bundle/root/etc/fstab"

# ---------------------------------------------------------------------------
# Step 3: build the sha256 manifest. Every regular file under boot/ and
# root/ contributes an entry. Symlinks and directories are skipped (the
# verifier checks them implicitly by re-reading them during apply).
# meta.json itself is NOT in the manifest — it would be self-referential
# and unverifiable.
# ---------------------------------------------------------------------------
echo "build-bundle: generating sha256 manifest..."
MANIFEST_TMP="${WORK}/manifest.json"
(
    cd "${WORK}/bundle"
    # find -print0 + xargs -0 to handle filenames with spaces/special chars
    # Output: <hash>  <path>  (two-space separator per sha256sum)
    find boot root -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum
) > "${WORK}/sha256.txt"

# Convert the sha256sum output into a JSON object {path: hash, ...}.
# Use python because jq isn't guaranteed on the runner; python3 is.
python3 - "${WORK}/sha256.txt" "$MANIFEST_TMP" <<'PYEOF'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
manifest = {}
with open(src, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        # sha256sum prefixes binary-mode hashes with '*'; strip if present.
        digest, _, path = line.partition("  ")
        if path.startswith("*"):
            path = path[1:]
        manifest[path] = digest
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, indent=2)
PYEOF

# ---------------------------------------------------------------------------
# Step 4: write meta.json. Field set matches docs/bundle-format.md.
# ---------------------------------------------------------------------------
echo "build-bundle: writing meta.json (version=${VERSION}, builder=${BUILDER})..."
python3 - "$MANIFEST_TMP" "${WORK}/bundle/meta.json" "$VERSION" "$MIN_FROM_VERSION" "$BUNDLE_SCHEMA_VERSION" "$BUILDER" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

manifest_path, meta_path, version, min_from_version, schema_version, builder = sys.argv[1:7]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
meta = {
    "version": version,
    "min_from_version": min_from_version or None,
    "schema_version": int(schema_version),
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "builder": builder,
    "sha256_manifest": manifest,
}
with open(meta_path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, sort_keys=True, indent=2)
PYEOF

# ---------------------------------------------------------------------------
# Step 5: pack the 3-entry top-level tarball. Spec requires exactly
# boot/, root/, meta.json under the top level — any extra entry causes
# the device to fail apply with `failed:bundle_invalid`.
# ---------------------------------------------------------------------------
echo "build-bundle: tar + zstd compress (level ${ZSTD_LEVEL}, window-log ${ZSTD_WINDOW_LOG})..."
BUNDLE_TAR="${WORK}/bundle.tar"
(
    cd "${WORK}/bundle"
    # Explicit ordering matches reader expectations and keeps the
    # diff between two builds stable.
    tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$BUNDLE_TAR" \
        boot root meta.json
)

# Verify the top-level entry set BEFORE compression so a mis-structured
# tarball gets caught at build time, not at device-apply time.
TOP_ENTRIES="$(tar -tf "$BUNDLE_TAR" | awk -F/ '{print $1}' | sort -u | grep -v '^$')"
EXPECTED_ENTRIES="$(printf 'boot\nmeta.json\nroot\n')"
if [[ "$TOP_ENTRIES" != "$EXPECTED_ENTRIES" ]]; then
    echo "build-bundle: ERROR — bundle top-level entries malformed." >&2
    echo "  expected:" >&2
    printf '%s\n' "$EXPECTED_ENTRIES" | sed 's/^/    /' >&2
    echo "  got:" >&2
    printf '%s\n' "$TOP_ENTRIES" | sed 's/^/    /' >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_BUNDLE")"
zstd -"${ZSTD_LEVEL}" --long="${ZSTD_WINDOW_LOG}" -T0 -f \
    -o "$OUT_BUNDLE" "$BUNDLE_TAR"

# Quick sanity: confirm the output exists and is non-empty.
if [[ ! -s "$OUT_BUNDLE" ]]; then
    echo "build-bundle: ERROR — output bundle missing or empty: $OUT_BUNDLE" >&2
    exit 1
fi

OUT_SIZE="$(stat -c%s "$OUT_BUNDLE" 2>/dev/null || stat -f%z "$OUT_BUNDLE")"
echo "build-bundle: ${OUT_BUNDLE} (${OUT_SIZE} bytes)"

# ---------------------------------------------------------------------------
# Step 6: emit a separate sha256 of the .tar.zst itself (CDN verification,
# orthogonal to the minisign signature). Signature is appended by
# release.yml in a separate step.
# ---------------------------------------------------------------------------
(
    cd "$(dirname "$OUT_BUNDLE")"
    sha256sum "$(basename "$OUT_BUNDLE")" > "$(basename "$OUT_BUNDLE").sha256"
)

echo "build-bundle: done."

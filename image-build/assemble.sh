#!/usr/bin/env bash
# assemble.sh — bolt-on assembler stage (D55).
#
# Takes the rootfs + boot tarballs emitted by stock pi-gen and produces a
# flashable 2-partition GPT .img.xz per the Phase 0 design.
#
# The flashable image ships ONLY boot-A + root-A. agora-firstboot grows
# root-A from 5 GB to 8 GB and adds boot-B + root-B + data on the device's
# first boot. This keeps the .img.xz small and the SD-card write fast,
# instead of ~15 min for the full 18 GB layout. See docs/firstboot.md.
#
# Build-time root-A was originally sized at 3 GB but the stage-agora rootfs
# (Chromium with HEVC + agora .deb + locales) overflowed 3 GB and ENOSPC'd
# the tar extract. Bumped to 5 GB to give ~2 GB headroom for future deps.
#
# Usage:
#   assemble.sh <rootfs-tar> <boot-tar> <out-img-xz>
#
# Inputs are expected to be the standard pi-gen "export-image" stage output,
# unmodified.
#
# This file is the skeleton: every step is structured and ordered, but
# several sections call out TODOs whose pieces land in sibling Phase 0 todos
# (p0-eeprom-template, p0-firstboot-service, etc.).

set -euo pipefail

ROOTFS_TAR="${1:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-xz>}"
BOOT_TAR="${2:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-xz>}"
OUT_IMG_XZ="${3:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-xz>}"

# /etc/agora/version contents (F17, Decision #2). Fail fast: shipping
# literal "TODO" values to the field would silently break the os_updater
# floor check (it parses agora_os_version out of this file). release.yml
# is responsible for sourcing these from the git tag + the committed
# image-build/agora-app-floor.txt and passing them through sudo.
: "${AGORA_OS_VERSION:?AGORA_OS_VERSION env var required (e.g. '0.0.4-test'); release.yml sets this from \${GITHUB_REF_NAME#v}}"
: "${AGORA_APP_FLOOR:?AGORA_APP_FLOOR env var required (e.g. '1.11.0'); release.yml sets this from image-build/agora-app-floor.txt}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t agora-os-build.XXXXXX)"
trap 'cleanup' EXIT

IMG="${WORK}/agora-os.img"
# Raw image size. Partitions sum to 512 MB + 5120 MB = 5632 MB. We need
# headroom for (a) the 1 MB GPT-aligned start offset and (b) the backup
# GPT table at the end of the disk (~17 KB). 16 MB is plenty.
IMG_SIZE_MB=5648

cleanup() {
    set +e
    # Unmount anything we mounted.
    for mp in boot-A root-A; do
        if mountpoint -q "${WORK}/mnt/${mp}" 2>/dev/null; then
            umount "${WORK}/mnt/${mp}"
        fi
    done
    # Detach the loop device.
    if [[ -n "${LOOPDEV:-}" ]]; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "assemble.sh: must run as root (mount/losetup require it)." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: create the raw image and lay out the GPT.
# ---------------------------------------------------------------------------
create_image() {
    truncate -s "${IMG_SIZE_MB}M" "$IMG"
    "${HERE}/partition.sh" "$IMG"
}

# ---------------------------------------------------------------------------
# Step 2: attach a loop device with partition scanning.
# ---------------------------------------------------------------------------
attach_loop() {
    LOOPDEV="$(losetup --show --find --partscan "$IMG")"
    # Image-time partition numbering (final on-device numbering after
    # firstboot is documented in docs/firstboot.md):
    #   p1 = boot-A
    #   p2 = root-A
    # The remaining partitions (boot-B = p3, root-B = p4, data = p5) are
    # created by agora-firstboot.
    BOOT_A_DEV="${LOOPDEV}p1"
    ROOT_A_DEV="${LOOPDEV}p2"
}

# ---------------------------------------------------------------------------
# Step 3: format each partition.
# ---------------------------------------------------------------------------
format_partitions() {
    mkfs.vfat -F 32 -n boot-A "$BOOT_A_DEV"
    mkfs.ext4 -F -L root-A "$ROOT_A_DEV"
}

# ---------------------------------------------------------------------------
# Step 4: mount everything under ${WORK}/mnt.
# ---------------------------------------------------------------------------
mount_partitions() {
    mkdir -p "${WORK}/mnt/"{boot-A,root-A}
    mount "$ROOT_A_DEV" "${WORK}/mnt/root-A"
    mount "$BOOT_A_DEV" "${WORK}/mnt/boot-A"
}

# ---------------------------------------------------------------------------
# Step 5: untar pi-gen output into the slot-A pair.
# Per-slot specialization (cmdline.txt, fstab BOOT_PARTLABEL substitution)
# happens in step 6.
# ---------------------------------------------------------------------------
populate_slots() {
    tar -xf "$ROOTFS_TAR" -C "${WORK}/mnt/root-A"
    tar -xf "$BOOT_TAR"   -C "${WORK}/mnt/boot-A"
}

# ---------------------------------------------------------------------------
# Step 6: write per-slot boot config and fstab.
# Bookworm puts the FAT boot partition at /boot/firmware/ (F15).
# autoboot.txt's [tryboot] section already targets partition 3 (boot-B,
# created by firstboot); the [all] section targets partition 1 (boot-A).
# ---------------------------------------------------------------------------
write_boot_config() {
    install -m 0644 "${HERE}/cmdline-A.txt" "${WORK}/mnt/boot-A/cmdline.txt"
    install -m 0644 "${HERE}/autoboot.txt"  "${WORK}/mnt/boot-A/autoboot.txt"

    # root-A fstab (BOOT_PARTLABEL=boot-A). The root-B fstab is written by
    # the first OTA that populates boot-B + root-B.
    sed 's/{{BOOT_PARTLABEL}}/boot-A/' "${HERE}/fstab.template" \
        > "${WORK}/mnt/root-A/etc/fstab"
    chmod 0644 "${WORK}/mnt/root-A/etc/fstab"
}

# ---------------------------------------------------------------------------
# Step 7: rootfs customization (root-A only; root-B is populated by the
# first OTA bundle, not at image-build time).
#
# Delegates to customize-rootfs.sh so this image-build path and the OTA
# bundle producer (build-bundle.sh) install the SAME set of files into
# the rootfs. Prior to this refactor the bundle producer had drifted —
# v0.0.6-test's bundle shipped only an identity-strip + /etc/agora/version,
# missing pubkeys, firstboot, system.conf.d/agora.conf, logrotate,
# timesyncd, the fstab template, the apply.py mount-point dirs, and the
# EEPROM artifacts. That almost certainly bricked Pi 192.168.1.100 during
# the manual OTA: slot B had no /etc/fstab.template for apply.py to
# substitute and no pubkeys for any future bundle to verify against.
# ---------------------------------------------------------------------------
customize_rootfs() {
    "${HERE}/customize-rootfs.sh" "${WORK}/mnt/root-A" "${WORK}/mnt/boot-A"
}

# ---------------------------------------------------------------------------
# Step 8: tear down mounts, detach loop, compress the image.
# Data partition seeding (SCHEMA_VERSION, /data/var-log/) is deferred to
# agora-firstboot because the data partition doesn't exist yet at image
# build time.
# ---------------------------------------------------------------------------
finalize_image() {
    sync
    umount "${WORK}/mnt/boot-A"
    umount "${WORK}/mnt/root-A"
    losetup -d "$LOOPDEV"
    LOOPDEV=""

    mkdir -p "$(dirname "$OUT_IMG_XZ")"
    # F19 (superseded): the flashable image uses xz, not zstd.
    # Pi Imager + balenaEtcher both read the uncompressed size from the xz
    # footer to render an accurate progress bar; zstd's frame header doesn't
    # expose that reliably so the progress bar overshoots 1000%+. OTA bundles
    # (Phase 2) stay on zstd for fast on-Pi decompression — that's a different
    # trade-off (D17 unchanged).
    #
    # Preset -1 (not -9): the image is a one-time-flash artifact, downloaded
    # rarely and decompressed once per provisioned card. -9 cost ~2-4 min of
    # CI wall-time to shave ~200 MiB off a ~1 GiB asset; storage/bandwidth on
    # GitHub Releases is free, so the size delta is non-cost. -1 also has
    # slightly faster decompression (smaller dict) for Pi Imager and the CMS
    # imager's recompress pipeline (cms/services/imager.py:467 already uses
    # xz -1 for the same reason). -T0 uses every core.
    xz -T0 -1 -f -c "$IMG" > "$OUT_IMG_XZ"
    echo "wrote ${OUT_IMG_XZ}"
}

main() {
    require_root
    create_image
    attach_loop
    format_partitions
    mount_partitions
    populate_slots
    write_boot_config
    customize_rootfs
    finalize_image
}

main "$@"

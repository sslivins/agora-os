#!/bin/bash -e
# pi-gen substep: Install HEVC-enabled chromium from sslivins/chromium-rpi-hevc.
#
# Why: the Agora .deb has `Depends: chromium`. By default apt would pull
# the stock Pi-OS chromium-browser (no HEVC HW decode on Pi 5). We replace
# it here with our patched build before the agora install runs, so apt's
# dependency resolution picks up the already-installed package.
#
# This is a verbatim port from sslivins/agora's stage-agora — see that
# repo for upstream history. The agora-os overlay only targets pi5
# (D60 board hardcode), but the chromium-rpi-hevc patches are
# additive/fallback-safe so the script content needs no per-board
# branching.
#
# ── Bumping the chromium-rpi-hevc version ──
# 1. Update CHROMIUM_HEVC_TAG below to the new release tag.
# 2. Update CHROMIUM_HEVC_DEB_VERSION to the .deb filename version part
#    (the segment between the package name and "_arm64.deb"/"_all.deb").
# 3. Recompute SHA256 digests for the four assets and update
#    CHROMIUM_HEVC_DIGESTS below. From this directory:
#       for f in chromium chromium-common chromium-sandbox; do
#         curl -fLs -o /tmp/$f.deb \
#           "https://github.com/sslivins/chromium-rpi-hevc/releases/download/<TAG>/${f}_<VER>_arm64.deb"
#         sha256sum /tmp/$f.deb
#       done
#       curl -fLs -o /tmp/chromium-l10n.deb \
#         "https://github.com/sslivins/chromium-rpi-hevc/releases/download/<TAG>/chromium-l10n_<VER>_all.deb"
#       sha256sum /tmp/chromium-l10n.deb

CHROMIUM_HEVC_TAG="chromium-153.0.8010.47-2-rpt1-hevc1"
CHROMIUM_HEVC_DEB_VERSION="153.0.8010.47-2.deb13u1+rpt1"

# SHA256 digests, pinned to detect mutated/replaced release assets.
# Format: <sha256>  <filename>
CHROMIUM_HEVC_DIGESTS="$(cat <<'DIGESTS'
28d0cc79456057079e6c544da67811951036bfa3cbda828405c17c418d97c4c7  chromium_153.0.8010.47-2.deb13u1+rpt1_arm64.deb
bd1aa11331e74cfaedc32b84532a6e2326bc9d215d5badae248dc2ebc81445c0  chromium-common_153.0.8010.47-2.deb13u1+rpt1_arm64.deb
c7a93e9ed75c5db4f936574235fc08948eb794d2cd336e7701beca0d612cb5e6  chromium-sandbox_153.0.8010.47-2.deb13u1+rpt1_arm64.deb
aee20f9bd1bf1c5c2f5263988698932886b324dad4561067d9d227485bd00740  chromium-l10n_153.0.8010.47-2.deb13u1+rpt1_all.deb
DIGESTS
)"

# Stage debs under /var/tmp inside ROOTFS_DIR. /tmp inside the chroot is
# masked by a tmpfs mount during on_chroot, so host-staged files there
# are invisible to the chroot. /var/tmp is real rootfs.
HOST_DEB_DIR="${ROOTFS_DIR}/var/tmp/chromium-hevc"
mkdir -p "${HOST_DEB_DIR}"

REL_BASE="https://github.com/sslivins/chromium-rpi-hevc/releases/download/${CHROMIUM_HEVC_TAG}"

echo "Agora: fetching chromium-rpi-hevc ${CHROMIUM_HEVC_TAG} debs..."
while read -r expected_sha filename; do
    [ -z "${filename}" ] && continue
    echo "  - ${filename}"
    curl -fL --retry 3 --retry-delay 5 -o "${HOST_DEB_DIR}/${filename}" \
        "${REL_BASE}/${filename}"
done <<< "${CHROMIUM_HEVC_DIGESTS}"

# Verify SHA256 digests before exposing them to the chroot's apt.
echo "Agora: verifying chromium-rpi-hevc deb digests..."
( cd "${HOST_DEB_DIR}" && echo "${CHROMIUM_HEVC_DIGESTS}" | sha256sum -c - )

# Install inside chroot. apt resolves Depends from Debian/Pi-OS repos
# (libgbm1, libnss3, ...) and Recommends (rpi-chromium-mods,
# libwidevinecdm0) — matches stock Pi-OS chromium install behavior.
on_chroot <<'CHEOF'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y /var/tmp/chromium-hevc/*.deb

# Hold so a later `apt-get upgrade` or tenant repo doesn't replace our
# HEVC-patched build with stock Pi-OS chromium.
apt-mark hold chromium chromium-common chromium-sandbox chromium-l10n

rm -rf /var/tmp/chromium-hevc
CHEOF

# Stamp install marker (runs on host — straightforward var expansion).
mkdir -p "${ROOTFS_DIR}/opt/agora/persist"
cat > "${ROOTFS_DIR}/opt/agora/persist/chromium-build" <<STAMP
source=sslivins/chromium-rpi-hevc
tag=${CHROMIUM_HEVC_TAG}
deb_version=${CHROMIUM_HEVC_DEB_VERSION}
STAMP

echo "Agora: chromium-rpi-hevc ${CHROMIUM_HEVC_TAG} installed."

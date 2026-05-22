#!/bin/bash -e
# pi-gen substep: Pin Pi5 kernel to 6.12.75 to work around a regression in
# 6.18.x where the V4L2 HEVC decoder (rpivid / hevc_dec) negotiates
# V4L2_PIX_FMT_NV12MT_*COL128 (SAND128 tiling). Mesa v3d on the same kernel
# cannot import dma-bufs with DRM_FORMAT_MOD_BROADCOM_SAND128 modifier for
# the R8 plane, so chromium's zero-copy EGL import path produces solid green
# frames for HEVC content. (mpv works because it has a hevc-drm-copy
# fallback that memcpys the decoded frame out and re-uploads as plain
# yuv420p, bypassing the import.)
#
# This substage:
#   1. Downloads the 6.12.75-1+rpt1 kernel .deb + its meta-package from
#      archive.raspberrypi.com (still in the pool).
#   2. Verifies SHA256 digests.
#   3. dpkg --install over whatever kernel apt pulled in 00-base-packages
#      (currently 6.18.29). --force-downgrade allows replacing the newer
#      kernel; --force-confold keeps any conffiles pi-gen has already set.
#   4. apt-mark hold linux-image-rpi-2712 + the versioned package so a
#      subsequent apt-get upgrade can't roll us back to 6.18.
#
# Reversing this:
#   - Delete this substage.
#   - `apt-mark unhold linux-image-rpi-2712 linux-image-6.12.75+rpt-rpi-2712`
#     on existing devices, then `apt-get install --reinstall linux-image-rpi-2712`.
#
# Upstream fix: when raspberrypi.com APT publishes a 6.18 kernel where
# pixelformat_from_sps() no longer advertises NV12MT_COL128 (reverting commit
# 2953bb2d91, 2026-01-15), drop this substage and let 00-base-packages pull
# the current kernel.

KERNEL_BASE_URL="http://archive.raspberrypi.com/debian/pool/main/l/linux"

# Two debs: the versioned kernel image (real bits) + the unversioned
# meta-package (so apt still has linux-image-rpi-2712 installed).
KERNEL_DEBS="$(cat <<'EOF'
4980f0626018b70499ab43fae5969e7c8662ac6938de987fc49755c34c2104d4  linux-image-6.12.75+rpt-rpi-2712_6.12.75-1+rpt1_arm64.deb
6610961e42eb513c1167017ba8b092e3084b6fd92b534a820a1fc0246118e22b  linux-image-rpi-2712_6.12.75-1+rpt1_arm64.deb
EOF
)"

# Stage debs under /var/tmp inside ROOTFS_DIR (chroot's /tmp is masked by
# tmpfs during on_chroot, but /var/tmp is real rootfs). Mirrors the
# pattern in 00-install-chromium-hevc/00-run.sh.
HOST_DEB_DIR="${ROOTFS_DIR}/var/tmp/kernel-612"
mkdir -p "${HOST_DEB_DIR}"

echo "Agora: fetching 6.12.75 kernel debs..."
while read -r expected_sha filename; do
    [ -z "${filename}" ] && continue
    echo "  - ${filename}"
    curl -fL --retry 3 --retry-delay 5 -o "${HOST_DEB_DIR}/${filename}" \
        "${KERNEL_BASE_URL}/${filename}"
done <<< "${KERNEL_DEBS}"

echo "Agora: verifying kernel deb digests..."
( cd "${HOST_DEB_DIR}" && echo "${KERNEL_DEBS}" | sha256sum -c - )

# Install inside chroot. dpkg --force-downgrade because 00-base-packages
# already brought in linux-image-rpi-2712 (currently 6.18.x) and we're
# replacing it with an older version.
on_chroot <<'CHEOF'
set -e
# Find whatever versioned kernel the base install pulled, so we can purge it
# AFTER we've installed 6.12.75 (avoid an unbootable in-between state).
CURRENT_VERSIONED="$(dpkg-query -W -f='${Package}\n' 'linux-image-*+rpt-rpi-2712' 2>/dev/null \
    | grep -v -- '-dbg$' | grep -v '^linux-image-rpi-2712$' || true)"
echo "Agora: existing versioned kernel(s): ${CURRENT_VERSIONED:-<none>}"

DEBIAN_FRONTEND=noninteractive dpkg \
    --force-downgrade \
    --force-confold \
    --install /var/tmp/kernel-612/*.deb

# Purge the 6.18 kernel image now that 6.12.75 is installed (keeps /boot
# clean and shrinks the rootfs). Skip if the only version found IS 6.12.75
# (shouldn't happen, but safe).
for pkg in $CURRENT_VERSIONED; do
    case "$pkg" in
        linux-image-6.12.75*) echo "Agora: keeping $pkg" ;;
        linux-image-*+rpt-rpi-2712)
            echo "Agora: purging $pkg"
            DEBIAN_FRONTEND=noninteractive apt-get -y purge "$pkg" || true
            ;;
    esac
done

# Hold both packages so a later `apt-get upgrade` (or tenant-side update)
# can't restore the broken 6.18 kernel.
apt-mark hold linux-image-rpi-2712 linux-image-6.12.75+rpt-rpi-2712

rm -rf /var/tmp/kernel-612
CHEOF

# Stamp marker so we know on-device which kernel pin policy this image
# was built with.
mkdir -p "${ROOTFS_DIR}/opt/agora/persist"
cat > "${ROOTFS_DIR}/opt/agora/persist/kernel-pin" <<STAMP
pinned_version=6.12.75-1+rpt1
pinned_reason=workaround-sand128-hevc-green-frame
source=http://archive.raspberrypi.com/debian/pool/main/l/linux
STAMP

echo "Agora: kernel pinned to 6.12.75-1+rpt1."

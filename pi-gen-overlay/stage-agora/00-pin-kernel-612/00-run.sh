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

# ─── Defensive: explicitly stamp the boot artifacts ───────────────────────
# The raspi-firmware z50 postinst.d hook copies vmlinuz → /boot/firmware/
# kernel_2712.img on install, but the postrm.d hook from the *purged* 6.18
# kernel runs AFTER our install and rewrites kernel_2712.img to whatever
# vmlinuz it finds next (in our case it picked the still-installed
# 6.18.29+rpt-rpi-v8 generic kernel, which is the wrong binary for Pi5).
# Empirically this leaves the device running 6.18 even though dpkg
# reports 6.12.75 as the only +rpt-rpi-2712 kernel.
#
# So do the copy ourselves AFTER all dpkg work, and verify by sha256.
PIN_VERSION="6.12.75+rpt-rpi-2712"
PIN_VMLINUZ="/boot/vmlinuz-${PIN_VERSION}"
if [ ! -f "${PIN_VMLINUZ}" ]; then
    echo "Agora: FATAL - ${PIN_VMLINUZ} missing after dpkg install" >&2
    exit 1
fi

# Ensure initramfs exists for 6.12 (raspi-firmware hook needs it for
# /boot/firmware/initramfs_2712).
update-initramfs -c -k "${PIN_VERSION}" 2>/dev/null \
    || update-initramfs -u -k "${PIN_VERSION}"

# Stamp the Pi5 boot kernel + initramfs.
mkdir -p /boot/firmware
cp -f "${PIN_VMLINUZ}" /boot/firmware/kernel_2712.img
if [ -f "/boot/initrd.img-${PIN_VERSION}" ]; then
    cp -f "/boot/initrd.img-${PIN_VERSION}" /boot/firmware/initramfs_2712
else
    echo "Agora: WARNING - /boot/initrd.img-${PIN_VERSION} missing; not updating initramfs_2712" >&2
fi

# Stamp Pi5 dtbs + overlays (they ship under /usr/lib/linux-image-<ver>/).
KERN_LIB="/usr/lib/linux-image-${PIN_VERSION}"
if [ -d "${KERN_LIB}/broadcom" ]; then
    # Pi5-family dtbs: bcm2712-*.dtb
    for dtb in ${KERN_LIB}/broadcom/bcm2712-*.dtb; do
        [ -f "$dtb" ] && cp -f "$dtb" /boot/firmware/
    done
fi
if [ -d "${KERN_LIB}/overlays" ]; then
    mkdir -p /boot/firmware/overlays
    cp -f ${KERN_LIB}/overlays/*.dtbo /boot/firmware/overlays/ 2>/dev/null || true
    [ -f ${KERN_LIB}/overlays/README ] && cp -f ${KERN_LIB}/overlays/README /boot/firmware/overlays/ || true
fi

# Verify kernel_2712.img is exactly the 6.12.75 binary.
SRC_SHA=$(sha256sum "${PIN_VMLINUZ}" | awk '{print $1}')
DST_SHA=$(sha256sum /boot/firmware/kernel_2712.img | awk '{print $1}')
if [ "${SRC_SHA}" != "${DST_SHA}" ]; then
    echo "Agora: FATAL - kernel_2712.img sha (${DST_SHA}) != vmlinuz-${PIN_VERSION} sha (${SRC_SHA})" >&2
    exit 1
fi
echo "Agora: kernel_2712.img verified as 6.12.75 (sha ${DST_SHA})"

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

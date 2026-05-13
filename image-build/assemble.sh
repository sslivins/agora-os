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
# ---------------------------------------------------------------------------
customize_rootfs() {
    local R="${WORK}/mnt/root-A"

    # logrotate cap for /var/log (D56).
    install -m 0644 "${HERE}/logrotate-agora.conf" \
        "${R}/etc/logrotate.d/agora"

    # /var/log bind-mount target (D56). fstab already points at it.
    mkdir -p "${R}/var/log"   # ensure the bind target exists in the slot

    # Strip per-device identity (F11) — firstboot regenerates these.
    : > "${R}/etc/machine-id"
    rm -f "${R}"/etc/ssh/ssh_host_*

    # Enable systemd-timesyncd (F20). Pi 5 has no RTC battery by default;
    # without NTP the device can boot at epoch 0.
    ln -sf /lib/systemd/system/systemd-timesyncd.service \
        "${R}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

    # Signing pubkeys for OTA bundle verification (D54).
    #
    # The real primary + recovery pubkeys are committed in this directory
    # and baked into the rootfs verbatim — there is NO build-time
    # substitution step. Rationale:
    #   - The signing keypair is permanent for the lifetime of the fleet
    #     (D54): rotating it requires a multi-release dance that itself
    #     depends on the *current* baked pubkey being trusted by every
    #     fielded device. There's nothing CI can substitute that the repo
    #     can't just commit.
    #   - The earlier .example placeholder design (with a TODO that no CI
    #     step ever fulfilled) silently shipped invalid pubkeys into the
    #     rootfs, breaking every OTA verify. The audit trail is in commit
    #     4fe4f59 ("Bake primary + recovery signing pubkeys").
    # The .example files remain in the repo as documentation of the
    # format; they are NOT installed.
    mkdir -p "${R}/etc/agora"
    install -m 0644 "${HERE}/update-pubkey.pem" \
        "${R}/etc/agora/update-pubkey.pem"
    install -m 0644 "${HERE}/update-pubkey-recovery.pem" \
        "${R}/etc/agora/update-pubkey-recovery.pem"
    # Rotation slot (Phase 2): the on-device verifier scans
    # /etc/agora/update-pubkeys.d/*.pem in addition to the two named
    # pubkeys above. Ship the directory empty so a future release can
    # drop a new key in without touching the verifier code.
    mkdir -p "${R}/etc/agora/update-pubkeys.d"

    # Version file (F17, Decision #2).
    # TODO(p0-release-pipeline): CI substitutes the real values.
    cat > "${R}/etc/agora/version" <<'EOF'
# Filled in by CI at build time.
agora_os_version=TODO
agora_app_floor=TODO
EOF

    # agora-firstboot.service: oneshot, idempotent. Runs early enough to
    # expand the partition table (step 1) BEFORE local-fs.target tries to
    # mount /data — because /data doesn't exist yet on a fresh flash; the
    # firstboot script creates it. See docs/firstboot.md.
    install -d -m 0755 "${R}/usr/local/sbin"
    install -m 0755 "${HERE}/firstboot/agora-firstboot.sh" \
        "${R}/usr/local/sbin/agora-firstboot"
    install -d -m 0755 "${R}/etc/systemd/system"
    install -m 0644 "${HERE}/firstboot/agora-firstboot.service" \
        "${R}/etc/systemd/system/agora-firstboot.service"
    # Enable via local-fs.target.wants (not sysinit.target.wants —
    # sysinit runs AFTER local-fs.target).
    install -d -m 0755 "${R}/etc/systemd/system/local-fs.target.wants"
    ln -sf /etc/systemd/system/agora-firstboot.service \
        "${R}/etc/systemd/system/local-fs.target.wants/agora-firstboot.service"

    # EEPROM artifacts go into /boot/firmware/ (the boot partition, not the
    # rootfs) because that's where rpi-eeprom-update / rpi-eeprom-config
    # look for staged updates. (p0-eeprom-template, F9). The first OTA will
    # write the same files to boot-B when it populates that partition.
    local B="${WORK}/mnt/boot-A"
    install -m 0644 "${HERE}/eeprom-config.template" \
        "${B}/agora-eeprom-config.txt"
    install -m 0644 "${HERE}/eeprom-floor.txt" \
        "${B}/agora-eeprom-floor.txt"
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
    # expose that reliably so the progress bar overshoots 1000%+. -T0 uses
    # every core, which keeps compress time within ~2x of single-thread zstd
    # on the arm runner. OTA bundles (Phase 2) stay on zstd for fast on-Pi
    # decompression — that's a different trade-off (D17 unchanged).
    xz -T0 -9 -f -c "$IMG" > "$OUT_IMG_XZ"
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

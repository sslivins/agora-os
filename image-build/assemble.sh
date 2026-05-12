#!/usr/bin/env bash
# assemble.sh — bolt-on assembler stage (D55).
#
# Takes the rootfs + boot tarballs emitted by stock pi-gen and produces a
# flashable 5-partition GPT .img.zst per the Phase 0 design.
#
# Usage:
#   assemble.sh <rootfs-tar> <boot-tar> <out-img-zst>
#
# Inputs are expected to be the standard pi-gen "export-image" stage output,
# unmodified.
#
# This file is the skeleton: every step is structured and ordered, but
# several sections call out TODOs whose pieces land in sibling Phase 0 todos
# (p0-eeprom-template, p0-firstboot-service, etc.).

set -euo pipefail

ROOTFS_TAR="${1:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-zst>}"
BOOT_TAR="${2:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-zst>}"
OUT_IMG_ZST="${3:?usage: assemble.sh <rootfs-tar> <boot-tar> <out-img-zst>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t agora-os-build.XXXXXX)"
trap 'cleanup' EXIT

IMG="${WORK}/agora-os.img"
# 18 GB raw image. Headroom: 2×512MB boot + 2×8GB root + 1GB data seed = 17.5 GB.
IMG_SIZE_MB=18432

cleanup() {
    set +e
    # Unmount anything we mounted.
    for mp in boot-A boot-B root-A root-B data; do
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
    # Map partition device names: /dev/loopXp1 .. /dev/loopXp5
    BOOT_A_DEV="${LOOPDEV}p1"
    BOOT_B_DEV="${LOOPDEV}p2"
    ROOT_A_DEV="${LOOPDEV}p3"
    ROOT_B_DEV="${LOOPDEV}p4"
    DATA_DEV="${LOOPDEV}p5"
}

# ---------------------------------------------------------------------------
# Step 3: format each partition.
# ---------------------------------------------------------------------------
format_partitions() {
    mkfs.vfat -F 32 -n boot-A "$BOOT_A_DEV"
    mkfs.vfat -F 32 -n boot-B "$BOOT_B_DEV"
    mkfs.ext4 -F -L root-A "$ROOT_A_DEV"
    mkfs.ext4 -F -L root-B "$ROOT_B_DEV"
    mkfs.ext4 -F -L data   "$DATA_DEV"
}

# ---------------------------------------------------------------------------
# Step 4: mount everything under ${WORK}/mnt.
# ---------------------------------------------------------------------------
mount_partitions() {
    mkdir -p "${WORK}/mnt/"{boot-A,boot-B,root-A,root-B,data}
    mount "$ROOT_A_DEV" "${WORK}/mnt/root-A"
    mount "$ROOT_B_DEV" "${WORK}/mnt/root-B"
    mount "$BOOT_A_DEV" "${WORK}/mnt/boot-A"
    mount "$BOOT_B_DEV" "${WORK}/mnt/boot-B"
    mount "$DATA_DEV"   "${WORK}/mnt/data"
}

# ---------------------------------------------------------------------------
# Step 5: untar pi-gen output into both slot pairs.
# Both root slots are byte-identical at build time; both boot slots are
# byte-identical at build time. Per-slot specialization (cmdline.txt, fstab
# BOOT_PARTLABEL substitution) happens in step 6.
# ---------------------------------------------------------------------------
populate_slots() {
    tar -xf "$ROOTFS_TAR" -C "${WORK}/mnt/root-A"
    tar -xf "$ROOTFS_TAR" -C "${WORK}/mnt/root-B"
    tar -xf "$BOOT_TAR"   -C "${WORK}/mnt/boot-A"
    tar -xf "$BOOT_TAR"   -C "${WORK}/mnt/boot-B"
}

# ---------------------------------------------------------------------------
# Step 6: write per-slot boot config and fstab.
# Bookworm puts the FAT boot partition at /boot/firmware/ (F15).
# autoboot.txt is byte-identical on both boot partitions (F6).
# ---------------------------------------------------------------------------
write_boot_config() {
    install -m 0644 "${HERE}/cmdline-A.txt" "${WORK}/mnt/boot-A/cmdline.txt"
    install -m 0644 "${HERE}/cmdline-B.txt" "${WORK}/mnt/boot-B/cmdline.txt"
    install -m 0644 "${HERE}/autoboot.txt"  "${WORK}/mnt/boot-A/autoboot.txt"
    install -m 0644 "${HERE}/autoboot.txt"  "${WORK}/mnt/boot-B/autoboot.txt"

    # Per-slot fstab with BOOT_PARTLABEL substituted in.
    sed 's/{{BOOT_PARTLABEL}}/boot-A/' "${HERE}/fstab.template" \
        > "${WORK}/mnt/root-A/etc/fstab"
    sed 's/{{BOOT_PARTLABEL}}/boot-B/' "${HERE}/fstab.template" \
        > "${WORK}/mnt/root-B/etc/fstab"
    chmod 0644 "${WORK}/mnt/root-A/etc/fstab" "${WORK}/mnt/root-B/etc/fstab"
}

# ---------------------------------------------------------------------------
# Step 7: per-slot rootfs customization.
# Applied identically to both root slots.
# ---------------------------------------------------------------------------
customize_rootfs() {
    for slot in root-A root-B; do
        local R="${WORK}/mnt/${slot}"

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
        mkdir -p "${R}/etc/agora"
        # TODO(p0-release-pipeline): these are committed as .example files;
        # CI substitutes the real pubkeys at build time.
        install -m 0644 "${HERE}/update-pubkey.pem.example" \
            "${R}/etc/agora/update-pubkey.pem"
        install -m 0644 "${HERE}/update-pubkey-recovery.pem.example" \
            "${R}/etc/agora/update-pubkey-recovery.pem"

        # Version file (F17, Decision #2).
        # TODO(p0-release-pipeline): CI substitutes the real values.
        cat > "${R}/etc/agora/version" <<'EOF'
# Filled in by CI at build time.
agora_os_version=TODO
agora_app_floor=TODO
EOF

        # agora-firstboot.service: oneshot, idempotent, runs before
        # local-fs.target so step 1 (grow partition 5) lands while
        # /data is still unmounted. See docs/firstboot.md.
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

    done

    # EEPROM artifacts go into /boot/firmware/ (the BOOT partitions, not the
    # rootfs slots) because that's where rpi-eeprom-update / rpi-eeprom-config
    # look for staged updates. Per F6 we keep boot-A and boot-B byte-identical
    # so both slots get the same files. Consumed by step 2 of
    # /usr/local/sbin/agora-firstboot on the device. (p0-eeprom-template, F9)
    for boot in boot-A boot-B; do
        local B="${WORK}/mnt/${boot}"
        install -m 0644 "${HERE}/eeprom-config.template" \
            "${B}/agora-eeprom-config.txt"
        install -m 0644 "${HERE}/eeprom-floor.txt" \
            "${B}/agora-eeprom-floor.txt"
    done
}

# ---------------------------------------------------------------------------
# Step 8: seed the data partition.
# ---------------------------------------------------------------------------
seed_data_partition() {
    echo 1 > "${WORK}/mnt/data/SCHEMA_VERSION"
    mkdir -p "${WORK}/mnt/data/var-log"
    chmod 0755 "${WORK}/mnt/data/var-log"
}

# ---------------------------------------------------------------------------
# Step 9: tear down mounts, detach loop, compress the image.
# ---------------------------------------------------------------------------
finalize_image() {
    sync
    umount "${WORK}/mnt/data"
    umount "${WORK}/mnt/boot-A"
    umount "${WORK}/mnt/boot-B"
    umount "${WORK}/mnt/root-A"
    umount "${WORK}/mnt/root-B"
    losetup -d "$LOOPDEV"
    LOOPDEV=""

    mkdir -p "$(dirname "$OUT_IMG_ZST")"
    # F19: zstd-compress, not xz. Matches OTA bundle compression in Phase 2
    # and is dramatically faster in CI.
    zstd -T0 -19 -f "$IMG" -o "$OUT_IMG_ZST"
    echo "wrote ${OUT_IMG_ZST}"
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
    seed_data_partition
    finalize_image
}

main "$@"

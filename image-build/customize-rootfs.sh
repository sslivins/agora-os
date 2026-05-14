#!/usr/bin/env bash
# customize-rootfs.sh — shared rootfs customization step.
#
# Consumed by both assemble.sh (slot-A of the flashable .img.xz) and
# build-bundle.sh (OTA bundle producer). Without this shared layer the
# bundle producer drifted out of parity with the image build:
# v0.0.6-test's bundle shipped only an identity-strip + version file,
# missing pubkeys, firstboot, system.conf.d, logrotate, timesyncd, the
# fstab template, and the apply.py mount-point dirs. That almost
# certainly bricked Pi 192.168.1.100 mid-OTA — slot B had no /etc/fstab
# template for apply.py to substitute, no pubkeys to verify a future
# bundle, and no firstboot/timesyncd to recover the install.
#
# What this script does NOT touch (caller's responsibility):
#   - /etc/fstab  — assemble.sh writes the slot-A-substituted file in
#                   write_boot_config(); apply.py on the device writes
#                   per-target-slot on the OTA path (PR #3 in agora).
#                   This script DOES install /etc/fstab.template so the
#                   substituter has a source on both paths.
#   - /boot/firmware/cmdline.txt — slot-specific; assemble.sh installs
#                   the pre-built cmdline-A.txt for slot A; apply.py
#                   owns the bundle path (PR #3 in agora).
#   - /boot/firmware/autoboot.txt — installed by assemble.sh for slot A.
#
# Usage:
#   customize-rootfs.sh <rootfs-dir> <boot-dir>
#
# Inputs:
#   $1 = path to the rootfs being customized (e.g.
#        ${WORK}/mnt/root-A for assemble.sh,
#        ${WORK}/bundle/root for build-bundle.sh)
#   $2 = path to the boot partition matching that rootfs (EEPROM
#        artifacts land here)
#
# Required env vars (callers must export):
#   AGORA_OS_VERSION   — e.g. "0.0.7-test", no v-prefix
#   AGORA_APP_FLOOR    — e.g. "1.11.0", no v-prefix

set -euo pipefail

R="${1:?usage: customize-rootfs.sh <rootfs-dir> <boot-dir>}"
B="${2:?usage: customize-rootfs.sh <rootfs-dir> <boot-dir>}"

: "${AGORA_OS_VERSION:?AGORA_OS_VERSION env var required (e.g. '0.0.7-test')}"
: "${AGORA_APP_FLOOR:?AGORA_APP_FLOOR env var required (e.g. '1.11.0')}"

# Defensive v-prefix strip (same rationale as build-bundle.sh:55) so
# callers can pass raw git-tag values without surprises.
AGORA_OS_VERSION="${AGORA_OS_VERSION#v}"
AGORA_APP_FLOOR="${AGORA_APP_FLOOR#v}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$R" ]]; then
    echo "customize-rootfs: rootfs dir does not exist: $R" >&2
    exit 1
fi
if [[ ! -d "$B" ]]; then
    echo "customize-rootfs: boot dir does not exist: $B" >&2
    exit 1
fi

echo "customize-rootfs: applying to ${R} (boot=${B})..."

# logrotate cap for /var/log (D56).
install -m 0644 "${HERE}/logrotate-agora.conf" \
    "${R}/etc/logrotate.d/agora"

# /var/log bind-mount target (D56). fstab.template points at it.
mkdir -p "${R}/var/log"

# /data mountpoint. fstab.template mounts PARTLABEL=data here; without
# this directory, data.mount fails with `mount: /data: mount point does
# not exist` and the /var/log bind-mount, /opt/agora/state, and
# /opt/agora/persist binds cascade-fail along with it. On the slot-A
# image path this masked itself because agora-firstboot creates the
# data partition and the dir survives via a kernel auto-mkdir on some
# kernels; on the OTA-applied slot-B path the dir was always missing
# and slot B booted with /data unmounted (cascade failure of all 4
# services). Bug #16.
mkdir -p "${R}/data"

# Strip per-device identity (F11, D63). On the slot-A flash path
# agora-firstboot regenerates these; on the OTA-apply path the D60
# fleet-state copy step in agora's os_updater/apply.py copies them
# from the running slot before triggering tryboot.
: > "${R}/etc/machine-id"
rm -f "${R}"/etc/ssh/ssh_host_*

# Enable systemd-timesyncd (F20). Pi 5 has no RTC battery by default;
# without NTP the device can boot at epoch 0.
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${R}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

# Disable systemd's hardware-watchdog ownership of /dev/watchdog0 so
# the python agora-watchdog.service can hold it instead
# (os-bug-v002-watchdog-contention).
install -d -m 0755 "${R}/etc/systemd/system.conf.d"
install -m 0644 "${HERE}/system.conf.d/agora.conf" \
    "${R}/etc/systemd/system.conf.d/agora.conf"

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

# Version file (F17, Decision #2). os_updater/main.py's
# _read_current_version() parses agora_os_version out of this file to
# drive the min_from_version floor check; agora_app_floor is the
# minimum agora-app version this rootfs supports.
cat > "${R}/etc/agora/version" <<EOF
# Generated by customize-rootfs.sh at build time. Do not hand-edit.
agora_os_version=${AGORA_OS_VERSION}
agora_app_floor=${AGORA_APP_FLOOR}
EOF
chmod 0644 "${R}/etc/agora/version"

# agora-firstboot.service: oneshot, idempotent. On the slot-A flash
# path it expands the partition table BEFORE local-fs.target tries to
# mount /data. On the OTA-bundle path firstboot's pre-conditions are
# all already true (partitions exist, /data is mounted), so every
# step short-circuits cleanly — but the unit must still ship in the
# OTA-applied slot so a future re-flash of that same SD card via
# `dd if=block-device.img` (operator recovery scenario) still gets
# the firstboot service.
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

# fstab template. Slot-A path (assemble.sh) writes a substituted
# /etc/fstab via write_boot_config() and keeps fstab.template
# alongside as documentation. OTA-bundle path (build-bundle.sh)
# ships only the template; apply.py on the device substitutes
# {{BOOT_PARTLABEL}} per target slot and writes /etc/fstab before
# triggering tryboot (PR #3 in agora).
install -m 0644 "${HERE}/fstab.template" \
    "${R}/etc/fstab.template"

# Mount-point directories that apply.py's preflight expects to exist
# on the active slot before staging an update. /boot/firmware-b is
# the bind target for the inactive boot partition; /mnt/inactive-root
# is where apply.py mounts the inactive root during apply. v0.0.6-test
# had to `mkdir -p` these by hand on the running device during the
# manual OTA — they belong baked into the rootfs.
mkdir -p "${R}/boot/firmware-b"
mkdir -p "${R}/mnt/inactive-root"

# EEPROM artifacts go into the boot partition (where rpi-eeprom-update
# / rpi-eeprom-config look for staged updates), not the rootfs
# (p0-eeprom-template, F9). Both callers stage these:
#   - slot-A flash: boot-A is what bootloader reads on first boot.
#   - OTA: slot-B's boot-B receives them so a slot flip doesn't strand
#     the EEPROM floor on the previous slot.
install -m 0644 "${HERE}/eeprom-config.template" \
    "${B}/agora-eeprom-config.txt"
install -m 0644 "${HERE}/eeprom-floor.txt" \
    "${B}/agora-eeprom-floor.txt"

echo "customize-rootfs: done."

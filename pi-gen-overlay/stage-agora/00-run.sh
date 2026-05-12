#!/usr/bin/env bash
# Pi-gen stage-agora — bolt-on overlay stage (D55).
#
# Stock pi-gen runs this stage after its standard stages to layer the
# Agora-specific customizations into the rootfs BEFORE assemble.sh splits
# the result into A/B slots.
#
# Stage-agora customizations belong here if they need to be in the rootfs
# tarball that pi-gen emits (i.e., they must persist across slot writes
# without per-slot specialization).
#
# Customizations that vary between root-A and root-B (cmdline.txt, fstab
# BOOT_PARTLABEL, etc.) live in image-build/assemble.sh instead.

set -euo pipefail

# Packages required by firstboot + future OTA path are installed via the
# adjacent 00-packages file (pi-gen reads it automatically). Specifically:
#   - gdisk          → sgdisk (firstboot layout expand)
#   - parted         → parted + partprobe (firstboot partition grow)
#   - dosfstools     → mkfs.vfat for boot-B
#   - e2fsprogs      → mkfs.ext4 / resize2fs (usually present, defensive)
#   - rpi-eeprom     → rpi-eeprom-config + rpi-eeprom-update (firstboot EEPROM floor)
#   - minisign       → OTA signature verification (Phase 2)
#   - zstd           → OTA bundle decompression (Phase 2)
#
# TODO(p0-pi-gen-overlay-followup): real overlay content lands here once
# we identify the minimum set of packages/services we want baked into the
# rootfs upstream of slot specialization. Likely candidates:
#   - apt-install minisign, zstd, gdisk (needed by agora-slot-mgr)
#   - apt-install rpi-eeprom (for firstboot floor enforcement)
#   - disable unattended-upgrades (we manage OS updates via OTA)
#   - drop in agora-app systemd unit skeleton
#   - drop in agora-slot-mgr systemd unit skeleton

echo "stage-agora 00-run.sh: placeholder, no-op."

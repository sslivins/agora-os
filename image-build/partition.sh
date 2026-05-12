#!/usr/bin/env bash
# partition.sh — lay out a 2-partition GPT inside the flashable .img.
#
# Usage: partition.sh <path-to-img>
#
# Per D51 the partitions get GPT names (sgdisk -c) so the kernel can resolve
# the rootfs via `root=PARTLABEL=...` without depending on dynamic PARTUUIDs.
#
# The flashable image ships ONLY boot-A + root-A. agora-firstboot expands
# the partition table on first boot to add boot-B, root-B, and data, and
# grows root-A from its build-time 3 GB up to the production 8 GB (D52). This
# keeps the flashable image ~3.5 GB raw (~600 MB compressed) so writing an
# SD card takes ~3 min instead of ~15 min for the full 18 GB layout.
#
# IMAGE partition sizes (final on-device layout is documented in
# docs/firstboot.md):
#   1  boot-A   512 MB  FAT32 (filesystem made later by assemble.sh)
#   2  root-A     3 GB  ext4  (agora-firstboot grows to 8 GB)

set -euo pipefail

IMG="${1:?usage: partition.sh <path-to-img>}"

# Wipe any existing partition table and create a fresh GPT.
sgdisk --zap-all "$IMG"

# Create partitions. End positions use sgdisk's +<size> syntax.
# Type code 0700 = "Microsoft basic data" (works for FAT and Linux ext4 alike;
# the kernel doesn't care about the type code, only PARTLABEL).
sgdisk \
    --new=1:1MiB:+512MiB    --change-name=1:boot-A  --typecode=1:0700 \
    --new=2:0:+3072MiB      --change-name=2:root-A  --typecode=2:0700 \
    "$IMG"

# Sanity print so build logs show the final layout.
sgdisk --print "$IMG"

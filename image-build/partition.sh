#!/usr/bin/env bash
# partition.sh — lay out the 5-partition GPT inside an existing .img file.
#
# Usage: partition.sh <path-to-img>
#
# Per D51 the partitions get GPT names (sgdisk -c) so the kernel can resolve
# the rootfs via `root=PARTLABEL=...` without depending on dynamic PARTUUIDs.
# Per D52 root slots are 8 GB each; the data partition fills whatever remains
# (target floor is a 32 GB SD card — the device-side firstboot resizes the
# data partition to fill the actual card).
#
# Partition sizes (sectors are 512 B):
#   1  boot-A   512 MB  FAT32 (filesystem made later by assemble.sh)
#   2  boot-B   512 MB  FAT32
#   3  root-A     8 GB  ext4
#   4  root-B     8 GB  ext4
#   5  data    1024 MB  ext4 (firstboot resizes this to fill the SD)

set -euo pipefail

IMG="${1:?usage: partition.sh <path-to-img>}"

# Wipe any existing partition table and create a fresh GPT.
sgdisk --zap-all "$IMG"

# Create partitions. End positions use sgdisk's +<size> syntax.
# Type code 0700 = "Microsoft basic data" (works for FAT and Linux ext4 alike;
# the kernel doesn't care about the type code, only PARTLABEL).
sgdisk \
    --new=1:1M:+512M       --change-name=1:boot-A  --typecode=1:0700 \
    --new=2:0:+512M        --change-name=2:boot-B  --typecode=2:0700 \
    --new=3:0:+8G          --change-name=3:root-A  --typecode=3:0700 \
    --new=4:0:+8G          --change-name=4:root-B  --typecode=4:0700 \
    --new=5:0:+1024M       --change-name=5:data    --typecode=5:0700 \
    "$IMG"

# Sanity print so build logs show the final layout.
sgdisk --print "$IMG"

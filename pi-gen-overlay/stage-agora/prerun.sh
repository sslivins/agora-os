#!/usr/bin/env bash
# Pi-gen stage-agora prerun.sh — copies the previous stage's rootfs into
# this stage's work directory so 00-run.sh can customize it.
#
# This is the standard pi-gen prerun.sh pattern; the only reason it's not
# a one-liner shipping `cp -a ${prev_rootfs} ${rootfs_dir}` is that pi-gen
# expects this file to exist per-stage.

set -euo pipefail

if [[ -n "${PREV_ROOTFS_DIR:-}" ]] && [[ -d "$PREV_ROOTFS_DIR" ]]; then
    if [[ ! -d "$ROOTFS_DIR" ]]; then
        cp -a "$PREV_ROOTFS_DIR" "$ROOTFS_DIR"
    fi
fi

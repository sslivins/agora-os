#!/bin/bash -e
# Pi-gen stage-agora prerun.sh -- borrowed from sslivins/agora.
# copy_previous is a pi-gen-provided function (sourced from
# scripts/dependencies_check + main build script) that copies the prior
# stage's rootfs into this stage's work dir so 00-run.sh + export-image
# can operate on it. Without this, the rootfs is empty and export-image
# tries to size a zero-byte partition (fails with "location outside of
# device").
copy_previous

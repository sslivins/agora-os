#!/bin/bash
#
# /usr/local/sbin/agora-firstboot — agora-os firstboot, run by agora-firstboot.service
#
# Design (see agora-cms#544 + plan.md, todo p0-firstboot-service):
#   * Oneshot systemd unit ordered Before=local-fs.target so /data isn't
#     yet mounted when step 1 (resize) runs (F8).
#   * NO sentinel gate (F5). Every step short-circuits on its own
#     post-condition so:
#       - rebooting the device twice produces no log noise from this unit
#       - dd-cloning the SD onto a fresh card lights up firstboot cleanly
#         (a sentinel-gated design would skip resize on the clone)
#   * Each step on internal failure logs ERROR and returns 0, so a
#     bad-cards-but-bootable Pi still gets to multi-user.target. The unit
#     itself only exits non-zero on truly catastrophic plumbing failure.
#
# Steps:
#   1. Grow partition 5 (PARTLABEL=data) to fill the device + resize2fs (F8).
#   2. Apply pinned EEPROM floor if current < floor (F9, F14: takes effect
#      on next power-cycle, not soft reboot).
#   3. Regenerate /etc/machine-id and ssh host keys if missing (F11).
#   4. Enable + start systemd-timesyncd (F20).
#   5. Drop /data/.firstboot-done breadcrumb (informational only, NOT gating).

set -u
shopt -s nullglob

LOG_PREFIX="[agora-firstboot]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Step 1: grow partition 5 (PARTLABEL=data) to fill the device (F8).
#
# Pre-mount per F8 — unit ordering enforces Before=local-fs.target. Uses
# `parted resizepart ... 100%` + `resize2fs`, both idempotent:
#   * parted on an already-100% partition either no-ops or makes a trivial
#     trailing-sector adjustment.
#   * resize2fs on an already-max-size ext4 prints "Nothing to do" and
#     exits 0.
# ---------------------------------------------------------------------------
step_resize_data() {
    local data_dev disk part_num

    data_dev=$(blkid -L data 2>/dev/null) || true
    if [[ -z "$data_dev" ]]; then
        warn "step 1: no partition with PARTLABEL=data; skipping resize"
        return 0
    fi

    if mountpoint -q /data; then
        warn "step 1: /data already mounted (unit ordering issue?); skipping resize"
        return 0
    fi

    disk=$(lsblk -ndo PKNAME "$data_dev" 2>/dev/null || true)
    part_num="${data_dev##*[!0-9]}"
    if [[ -z "$disk" || -z "$part_num" ]]; then
        err "step 1: could not derive disk/partition from ${data_dev}"
        return 0
    fi

    log "step 1: growing /dev/${disk} partition ${part_num} to 100%"
    if ! parted -s "/dev/${disk}" resizepart "${part_num}" 100%; then
        # parted sometimes returns non-zero with a warning when the
        # partition is already at the end; that's benign. Real failure
        # will show up in resize2fs below.
        warn "step 1: parted resizepart non-zero (possibly benign); continuing"
    fi
    partprobe "/dev/${disk}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    log "step 1: resizing ext4 filesystem on ${data_dev}"
    if ! resize2fs "${data_dev}"; then
        err "step 1: resize2fs failed; continuing without resize"
        return 0
    fi
    log "step 1: data partition + filesystem now fill device"
}

# ---------------------------------------------------------------------------
# Step 2: apply pinned EEPROM config + firmware floor (F9, F14).
#
# Two halves, both idempotent (no sentinel needed):
#
#   (a) Config: compare desired values from /boot/firmware/agora-eeprom-config.txt
#       (BOOT_ORDER, NET_INSTALL_AT_POWER_ON, BOOT_UART, ...) against the
#       running EEPROM config via `rpi-eeprom-config`. If any value differs,
#       run `rpi-eeprom-config --apply` to stage the change. Closes agora#165.
#
#   (b) Firmware floor: compare current bootloader timestamp (from
#       `vcgencmd bootloader_version`) against the floor value in
#       /boot/firmware/agora-eeprom-floor.txt. Run `rpi-eeprom-update -a` only
#       if current < floor.
#
# F14 caveat: BOTH operations stage updates for the NEXT power-cycle. A soft
# reboot will not pick them up. Acceptance testing (p0-acceptance) must
# explicitly power-cycle after firstboot to verify.
# ---------------------------------------------------------------------------
step_eeprom_floor() {
    step_eeprom_config
    step_eeprom_floor_only
}

# Step 2a: EEPROM config (BOOT_ORDER, NET_INSTALL_AT_POWER_ON, BOOT_UART).
step_eeprom_config() {
    local config_file="/boot/firmware/agora-eeprom-config.txt"

    if [[ ! -f "$config_file" ]]; then
        log "step 2a: no EEPROM config at ${config_file}; skipping"
        return 0
    fi
    if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
        warn "step 2a: rpi-eeprom-config not present; skipping config apply"
        return 0
    fi

    # Extract KEY=VALUE pairs from our config (strip comments + blanks).
    local desired
    desired=$(grep -vE '^\s*(#|$)' "$config_file" | grep '=' || true)
    if [[ -z "$desired" ]]; then
        warn "step 2a: no KEY=VALUE entries in ${config_file}; skipping"
        return 0
    fi

    # Get current EEPROM config. `rpi-eeprom-config` (no args) prints the
    # currently-staged or currently-installed config to stdout.
    local current needs_apply=0
    current=$(rpi-eeprom-config 2>/dev/null || true)

    local key val current_val
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        # Trim whitespace.
        key="${key// /}"
        val="${val// /}"
        current_val=$(echo "$current" | awk -F= -v k="$key" '$1==k {print $2; exit}')
        current_val="${current_val// /}"
        if [[ "$current_val" != "$val" ]]; then
            log "step 2a: EEPROM config ${key} differs (current='${current_val}', desired='${val}')"
            needs_apply=1
        fi
    done <<<"$desired"

    if (( needs_apply == 0 )); then
        log "step 2a: EEPROM config already matches; no apply needed"
        return 0
    fi

    log "step 2a: applying EEPROM config from ${config_file}"
    log "step 2a: NOTE — takes effect on next POWER-CYCLE, not soft-reboot (F14)"
    if ! rpi-eeprom-config --apply "$config_file"; then
        err "step 2a: rpi-eeprom-config --apply failed; continuing"
        return 0
    fi
}

# Step 2b: pinned bootloader firmware floor.
step_eeprom_floor_only() {
    local floor_file="/boot/firmware/agora-eeprom-floor.txt"
    local floor_ver current_ver

    if [[ ! -f "$floor_file" ]]; then
        log "step 2b: no EEPROM floor file at ${floor_file}; skipping"
        return 0
    fi

    # Strip comments + blank lines; take the first remaining token.
    floor_ver=$(grep -vE '^\s*(#|$)' "$floor_file" | head -n1 | awk '{print $1}')
    if [[ -z "$floor_ver" || "$floor_ver" == TODO* ]]; then
        log "step 2b: EEPROM floor is still a placeholder; skipping"
        return 0
    fi

    if ! command -v vcgencmd >/dev/null 2>&1; then
        warn "step 2b: vcgencmd not present; skipping floor check"
        return 0
    fi
    if ! command -v rpi-eeprom-update >/dev/null 2>&1; then
        warn "step 2b: rpi-eeprom-update not present; skipping floor enforcement"
        return 0
    fi

    # `vcgencmd bootloader_version` prints lines like:
    #   2024/12/05 16:54:12
    #   version e10ee29...
    #   timestamp 1733417652
    # We use the unix timestamp line as the comparison value (monotonic).
    current_ver=$(vcgencmd bootloader_version 2>/dev/null \
        | awk '/^timestamp /{print $2}' | head -n1)
    if [[ -z "$current_ver" ]]; then
        warn "step 2b: could not parse current EEPROM timestamp; skipping"
        return 0
    fi

    if (( current_ver < floor_ver )); then
        log "step 2b: EEPROM current=${current_ver} < floor=${floor_ver}; staging update"
        log "step 2b: NOTE — update takes effect on next POWER-CYCLE, not soft-reboot (F14)"
        if ! rpi-eeprom-update -d -a; then
            err "step 2b: rpi-eeprom-update failed; continuing"
            return 0
        fi
    else
        log "step 2b: EEPROM current=${current_ver} >= floor=${floor_ver}; no update needed"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: regenerate per-device identity if missing (F11).
#
# /etc/machine-id and /etc/ssh/ssh_host_* were stripped from the baked
# image so every flashed device gets unique identity. systemd-machine-id-setup
# and `ssh-keygen -A` are both natively idempotent (no-op if files exist),
# so even the conditional wrapping below is belt-and-suspenders.
# ---------------------------------------------------------------------------
step_regen_identity() {
    if [[ ! -s /etc/machine-id ]]; then
        log "step 3: regenerating /etc/machine-id"
        systemd-machine-id-setup || warn "step 3: systemd-machine-id-setup failed"
    else
        log "step 3: /etc/machine-id already populated; skipping"
    fi

    local existing
    existing=( /etc/ssh/ssh_host_*_key )
    if (( ${#existing[@]} > 0 )); then
        log "step 3: ssh host keys already present; skipping"
    else
        log "step 3: generating ssh host keys (ssh-keygen -A)"
        ssh-keygen -A || warn "step 3: ssh-keygen -A failed"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: ensure systemd-timesyncd is enabled + running (F20).
#
# Pi 5 has no RTC battery by default; without NTP a fresh boot lands at
# epoch 0, breaking TLS handshakes against any backend with a recent cert.
# The unit was symlinked into sysinit.target.wants at image-build time
# (see customize_rootfs in assemble.sh) so this is belt-and-suspenders.
# Both `enable` and `start` are idempotent in systemd.
# ---------------------------------------------------------------------------
step_timesyncd() {
    if systemctl is-enabled systemd-timesyncd.service >/dev/null 2>&1; then
        log "step 4: systemd-timesyncd already enabled"
    else
        log "step 4: enabling systemd-timesyncd"
        systemctl enable systemd-timesyncd.service || warn "step 4: enable failed"
    fi

    if systemctl is-active systemd-timesyncd.service >/dev/null 2>&1; then
        log "step 4: systemd-timesyncd already running"
    else
        log "step 4: starting systemd-timesyncd"
        systemctl start systemd-timesyncd.service || warn "step 4: start failed"
    fi
}

# ---------------------------------------------------------------------------
# Step 5: write the informational breadcrumb to /data (NOT gating).
#
# We mount /data manually here (after step 1 grew it). systemd's data.mount
# unit, scheduled for after our unit by local-fs.target, will recognize
# the existing mount via /proc/self/mountinfo and become a no-op.
# ---------------------------------------------------------------------------
step_breadcrumb() {
    local marker="/data/.firstboot-done"

    if ! mountpoint -q /data; then
        log "step 5: mounting /data to write breadcrumb"
        mkdir -p /data
        if ! mount /data 2>/dev/null; then
            warn "step 5: could not mount /data (fstab issue?); skipping breadcrumb"
            return 0
        fi
    fi

    if [[ ! -f "$marker" ]]; then
        date -Iseconds > "$marker" 2>/dev/null || true
        log "step 5: wrote breadcrumb to ${marker}"
    else
        log "step 5: breadcrumb already at ${marker} (firstboot has run on this card before)"
    fi
}

# ---------------------------------------------------------------------------
main() {
    log "starting (idempotent, no sentinel-gate per F5)"
    step_resize_data
    step_eeprom_floor
    step_regen_identity
    step_timesyncd
    step_breadcrumb
    log "done"
}

main "$@"

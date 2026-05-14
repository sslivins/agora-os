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
#   1. Expand layout from the ship-time 2-partition image (boot-A + root-A)
#      to the on-device 5-partition layout: grow root-A from 5 GB to 8 GB,
#      add boot-B (P3, 512 MB), root-B (P4, 8 GB), data (P5, fills card).
#      Format the new partitions and seed /data (SCHEMA_VERSION=1, /data/var-log/).
#      Idempotent: short-circuits if P5 already exists. See docs/firstboot.md.
#   2. Grow partition 5 (PARTLABEL=data) to fill the device + resize2fs (F8).
#      In the normal flash path this is a no-op (step 1 already sized data
#      to fill the card). Still useful for dd-clone-to-bigger-SD flows.
#   3. Apply pinned EEPROM floor if current < floor (F9, F14: takes effect
#      on next power-cycle, not soft reboot).
#   4. Regenerate /etc/machine-id and ssh host keys if missing (F11).
#   5. Enable + start systemd-timesyncd (F20).
#   6. Drop /data/.firstboot-done breadcrumb (informational only, NOT gating).

set -u
shopt -s nullglob

LOG_PREFIX="[agora-firstboot]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# Mirror everything we print into a tmpfs file. On exit, main() best-effort
# copies it onto the FAT32 boot-A partition so a brick can be diagnosed by
# pulling the SD card and reading the log from Windows/macOS without needing
# ext4 access.
RUN_LOG="/run/agora-firstboot.log"
mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true
exec > >(tee -a "$RUN_LOG") 2>&1

# ---------------------------------------------------------------------------
# Preflight: verify the tools we rely on are actually installed in the rootfs.
# Without this, a missing tool (e.g. sgdisk if `gdisk` wasn't apt-installed)
# causes step 1 to silently `return 0`, the data partition never gets created,
# local-fs.target fails on PARTLABEL=data, and the device drops to emergency
# mode with no SSH access. Failing loudly here makes that class of bug obvious.
# ---------------------------------------------------------------------------
preflight_tools() {
    local tool missing=()
    for tool in sgdisk parted partprobe partx udevadm \
                mkfs.vfat mkfs.ext4 resize2fs blkid findmnt lsblk mountpoint; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        err "preflight: missing required tools: ${missing[*]}"
        err "preflight: install via pi-gen-overlay/stage-agora/00-packages"
        return 1
    fi
    log "preflight: all required tools present"
    return 0
}

# ---------------------------------------------------------------------------
# Step 1: expand the ship-time 2-partition layout to the on-device 5-partition
# layout.
#
# The flashable image is small (~3.5 GB raw, ~600 MB xz) and ships only
# boot-A (P1, 512 MB) + root-A (P2, 5 GB). This step:
#   * Grows root-A from 5 GB to 8 GB (online ext4 resize on mounted /).
#   * Adds boot-B (P3, 512 MB), root-B (P4, 8 GB), data (P5, fills card).
#   * Formats the three new partitions.
#   * Seeds /data with SCHEMA_VERSION=1 and creates /data/var-log/, /data/agora/.
#
# Idempotency: short-circuits if P5 already exists. Safe to re-run after
# any partial-failure crash mid-step because each sub-step has its own
# pre-condition check.
#
# Pre-mount per F8 — unit ordering enforces Before=local-fs.target — so
# /data isn't mounted yet (it doesn't even exist as a partition yet). The
# fstab line for /data resolves cleanly on local-fs.target after this step
# completes.
#
# root-B and boot-B stay empty (just FS headers) until the first OTA — see
# checkpoint 035. Acceptable for Phase 0 since there's no OTA yet.
# ---------------------------------------------------------------------------
step_layout_expand() {
    local root_dev disk

    # Idempotency check: if P5 exists by PARTLABEL=data, this step has
    # already run successfully. Skip.
    if blkid -L data >/dev/null 2>&1; then
        log "step 1: PARTLABEL=data already present; layout already expanded"
        return 0
    fi

    # Find the running root partition (e.g. /dev/mmcblk0p2) and derive the
    # parent disk (e.g. mmcblk0).
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ -z "$root_dev" ]]; then
        err "step 1: could not determine root device from findmnt; aborting expand"
        return 0
    fi
    disk=$(lsblk -ndo PKNAME "$root_dev" 2>/dev/null || true)
    if [[ -z "$disk" ]]; then
        err "step 1: could not derive parent disk from ${root_dev}; aborting expand"
        return 0
    fi
    local diskdev="/dev/${disk}"

    log "step 1: expanding layout on ${diskdev} (root=${root_dev})"

    # Move the backup GPT table to the end of the actual device. The image's
    # backup GPT sits at the image's tail (~3.6 GB in), not the SD card's
    # tail. Without -e, sgdisk's subsequent --new operations on space past
    # the image tail will be misaligned with the (still image-sized) GPT.
    log "step 1: sgdisk -e (move backup GPT to end of ${diskdev})"
    if ! sgdisk -e "$diskdev"; then
        err "step 1: sgdisk -e failed; aborting expand"
        return 0
    fi
    # partx -u syncs the kernel's in-memory partition table with the on-disk
    # table without requiring an unmounted disk (unlike partprobe / BLKRRPART
    # which fails with EBUSY on a mounted root). udevadm settle then waits
    # for /dev/disk/by-partlabel/ symlinks to materialize.
    partx -u "$diskdev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # Grow root-A (P2) from 5 GB to 8 GB. Partition 2 starts at 513 MiB
    # (1 MiB GPT start + 512 MiB boot-A); end = 513 + 8192 = 8705 MiB.
    #
    # We use sgdisk (delete + recreate at same start sector) instead of
    # parted because parted refuses to resize a mounted partition: even
    # with `-s -f` it treats the "Partition is being used" warning as
    # PED_EXCEPTION_CANCEL in script mode and aborts (observed on
    # Debian trixie / parted 3.6). sgdisk only modifies the on-disk
    # GPT and doesn't care about kernel mount state; we then call
    # partx -u --nr 2 to push the new size into the kernel via
    # BLKPG_RESIZE_PARTITION (no unmount required).
    local p2_start
    p2_start=$(lsblk -no START "$root_dev" 2>/dev/null | tr -d ' \n')
    if [[ -z "$p2_start" ]]; then
        err "step 1: could not determine P2 start sector via lsblk; aborting expand"
        return 0
    fi
    log "step 1: sgdisk resizing P2 (root-A) to 8 GiB (start sector ${p2_start})"
    if ! sgdisk --delete=2 \
                --new=2:"${p2_start}":+8192MiB \
                --change-name=2:root-A \
                --typecode=2:0700 \
                "$diskdev"; then
        err "step 1: sgdisk resize of P2 failed; aborting expand"
        return 0
    fi
    # partx -u --nr 2 issues BLKPG_RESIZE_PARTITION which works on the busy
    # root partition; partprobe's BLKRRPART would fail with EBUSY here.
    partx -u --nr 2 "$diskdev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # Online ext4 resize of mounted /. Standard RPi OS init_resize.sh pattern.
    log "step 1: resize2fs on mounted root ${root_dev}"
    if ! resize2fs "$root_dev"; then
        err "step 1: resize2fs failed; continuing (P3/P4/P5 creation may still proceed)"
    fi

    # Add P3=boot-B (512 MiB), P4=root-B (8192 MiB = 8 GB), P5=data (rest).
    # 0700 is the GPT "Microsoft basic data" type; matches what assemble.sh
    # sets on P1/P2. -c sets the partition NAME which kernel exposes as
    # /dev/disk/by-partlabel/<name>.
    log "step 1: sgdisk creating P3 boot-B (512 MiB), P4 root-B (8 GiB), P5 data (rest)"
    if ! sgdisk \
            --new=3:0:+512MiB  -c 3:boot-B -t 3:0700 \
            --new=4:0:+8192MiB -c 4:root-B -t 4:0700 \
            --new=5:0:0        -c 5:data   -t 5:0700 \
            "$diskdev"; then
        err "step 1: sgdisk --new for P3/P4/P5 failed; aborting expand"
        return 0
    fi
    # partx -a adds newly-discovered partitions (P3/P4/P5) to the kernel's
    # view; partx -u alone won't pick up previously-unknown partitions.
    partx -a "$diskdev" 2>/dev/null || true

    # Tear down any stale mounts on /data and the /var/log bind mount BEFORE
    # touching the partitions. Why this order matters:
    #
    # On a dev/test reflash, sectors past P2 keep their old ext4 superblock
    # because Rufus/dd only writes the first ~8.5 GiB. If P5 already exists
    # in the GPT (e.g. left over from a prior cycle), systemd-fstab-generator
    # has already generated data.mount + var-log.mount + a systemd-fsck unit
    # at boot time from /etc/fstab. By the time firstboot.service runs:
    #   - systemd-fsck@dev-disk-by\x2dpartlabel-data has run (and possibly
    #     repaired) the stale ext4 fs on P5
    #   - data.mount has mounted P5 on /data
    #   - var-log.mount has bind-mounted /var/log -> /data/var-log
    # The bind mount holds /data busy, so a naive `umount /data` fails with
    # EBUSY, and a subsequent wipefs / mkfs.ext4 also fails with "device is
    # in use". We must stop var-log.mount FIRST to release the bind, then
    # data.mount, then unmount any stragglers. Lazy umount handles the case
    # where journald (or something else under /var/log) still holds a file
    # descriptor open; the fd will dangle until those processes exit, which
    # is fine because firstboot is about to recreate the filesystem anyway.
    #
    # All steps are best-effort: on a clean factory flash where P3/P4/P5
    # didn't exist before this very sgdisk call, none of these units ever
    # fired, and every stop / umount returns non-zero. The || true keeps
    # the script flowing.
    systemctl stop var-log.mount 2>/dev/null || true
    systemctl stop data.mount 2>/dev/null || true
    umount -l /var/log 2>/dev/null || true
    umount -l /data 2>/dev/null || true
    umount -l /dev/disk/by-partlabel/data 2>/dev/null || true

    # Now that /data is released, wipe any stale filesystem signatures on
    # the freshly-(re)created partitions so udev's next blkid probe finds
    # nothing to republish. Wiping by raw kernel device name avoids relying
    # on the by-partlabel/ symlinks (which only appear after udev runs and
    # whose target device may still be in a half-released state right after
    # the lazy umount above).
    for partdev in "${diskdev}p3" "${diskdev}p4" "${diskdev}p5"; do
        if [[ -b "$partdev" ]]; then
            wipefs -a "$partdev" 2>/dev/null || true
        fi
    done
    udevadm settle 2>/dev/null || true

    # Belt-and-suspenders: if udev managed to republish a signature between
    # the wipefs above and `settle` returning (or if data.mount somehow
    # got re-armed by a generator re-run), stop it again before mkfs.
    systemctl stop var-log.mount 2>/dev/null || true
    systemctl stop data.mount 2>/dev/null || true
    umount -l /data 2>/dev/null || true
    umount -l /dev/disk/by-partlabel/data 2>/dev/null || true

    # Format the three new partitions. -F forces mkfs.ext4 past its
    # "this looks like a partition table" sanity check (a fresh GPT entry
    # has no signature so this is belt-and-suspenders).
    log "step 1: mkfs.vfat boot-B, mkfs.ext4 root-B, mkfs.ext4 data"
    if ! mkfs.vfat -F 32 -n boot-B /dev/disk/by-partlabel/boot-B; then
        err "step 1: mkfs.vfat boot-B failed; continuing"
    fi
    if ! mkfs.ext4 -F -L root-B /dev/disk/by-partlabel/root-B; then
        err "step 1: mkfs.ext4 root-B failed; continuing"
    fi
    if ! mkfs.ext4 -F -F -L data /dev/disk/by-partlabel/data; then
        err "step 1: mkfs.ext4 data failed; aborting seed"
        return 0
    fi
    udevadm settle 2>/dev/null || true

    # Seed /data: SCHEMA_VERSION=1, /data/var-log/, /data/agora/. Mount
    # temporarily under /mnt/data; local-fs.target will (re-)mount under
    # /data via fstab in a few seconds.
    log "step 1: seeding /data (SCHEMA_VERSION=1, /data/var-log/, /data/agora/)"
    local seed_mnt
    seed_mnt=$(mktemp -d /tmp/data-seed.XXXXXX)
    if ! mount /dev/disk/by-partlabel/data "$seed_mnt"; then
        err "step 1: could not mount data partition for seeding; continuing"
        rmdir "$seed_mnt" 2>/dev/null || true
        return 0
    fi
    echo 1 > "${seed_mnt}/SCHEMA_VERSION"
    mkdir -p "${seed_mnt}/var-log" "${seed_mnt}/agora" "${seed_mnt}/agora/state" "${seed_mnt}/agora/persist"
    chmod 0755 "${seed_mnt}/var-log" "${seed_mnt}/agora" "${seed_mnt}/agora/state" "${seed_mnt}/agora/persist"
    sync
    umount "$seed_mnt"
    rmdir "$seed_mnt" 2>/dev/null || true

    log "step 1: layout expansion complete (root-A=8GB, boot-B/root-B/data created)"
}

# ---------------------------------------------------------------------------
# Step 2: REMOVED in Phase 0.
#
# Originally step 2 ran `parted resizepart 5 100%` + `resize2fs` to grow
# /data after the baked image (P1+P2 only) was dd'd onto a larger card.
# That role no longer exists: step 1's sgdisk creates P5 with
# `--new=5:0:0`, which always sizes the data partition to fill whatever
# disk the image is running on — there's nothing for step 2 to do.
#
# Keeping the step 2 invocation would: (a) re-run parted on an already-
# end-of-disk partition (no-op but noisy), and (b) trigger resize2fs to
# complain "Please run e2fsck first" because the partition geometry
# parted reports diverges by a sector or two from the freshly-mkfs'd FS,
# logging a spurious ERROR on every clean boot. So we drop it entirely.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 3: apply pinned EEPROM config + firmware floor (F9, F14).
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

# Step 3a: EEPROM config (BOOT_ORDER, NET_INSTALL_AT_POWER_ON, BOOT_UART).
step_eeprom_config() {
    local config_file="/boot/firmware/agora-eeprom-config.txt"

    if [[ ! -f "$config_file" ]]; then
        log "step 3a: no EEPROM config at ${config_file}; skipping"
        return 0
    fi
    if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
        warn "step 3a: rpi-eeprom-config not present; skipping config apply"
        return 0
    fi

    # Extract KEY=VALUE pairs from our config (strip comments + blanks).
    local desired
    desired=$(grep -vE '^\s*(#|$)' "$config_file" | grep '=' || true)
    if [[ -z "$desired" ]]; then
        warn "step 3a: no KEY=VALUE entries in ${config_file}; skipping"
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
            log "step 3a: EEPROM config ${key} differs (current='${current_val}', desired='${val}')"
            needs_apply=1
        fi
    done <<<"$desired"

    if (( needs_apply == 0 )); then
        log "step 3a: EEPROM config already matches; no apply needed"
        return 0
    fi

    log "step 3a: applying EEPROM config from ${config_file}"
    log "step 3a: NOTE — takes effect on next POWER-CYCLE, not soft-reboot (F14)"
    if ! rpi-eeprom-config --apply "$config_file"; then
        err "step 3a: rpi-eeprom-config --apply failed; continuing"
        return 0
    fi
}

# Step 3b: pinned bootloader firmware floor.
step_eeprom_floor_only() {
    local floor_file="/boot/firmware/agora-eeprom-floor.txt"
    local floor_ver current_ver

    if [[ ! -f "$floor_file" ]]; then
        log "step 3b: no EEPROM floor file at ${floor_file}; skipping"
        return 0
    fi

    # Strip comments + blank lines; take the first remaining token.
    floor_ver=$(grep -vE '^\s*(#|$)' "$floor_file" | head -n1 | awk '{print $1}')
    if [[ -z "$floor_ver" || "$floor_ver" == TODO* ]]; then
        log "step 3b: EEPROM floor is still a placeholder; skipping"
        return 0
    fi

    if ! command -v vcgencmd >/dev/null 2>&1; then
        warn "step 3b: vcgencmd not present; skipping floor check"
        return 0
    fi
    if ! command -v rpi-eeprom-update >/dev/null 2>&1; then
        warn "step 3b: rpi-eeprom-update not present; skipping floor enforcement"
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
        warn "step 3b: could not parse current EEPROM timestamp; skipping"
        return 0
    fi

    if (( current_ver < floor_ver )); then
        log "step 3b: EEPROM current=${current_ver} < floor=${floor_ver}; staging update"
        log "step 3b: NOTE — update takes effect on next POWER-CYCLE, not soft-reboot (F14)"
        if ! rpi-eeprom-update -d -a; then
            err "step 3b: rpi-eeprom-update failed; continuing"
            return 0
        fi
    else
        log "step 3b: EEPROM current=${current_ver} >= floor=${floor_ver}; no update needed"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: regenerate per-device identity if missing (F11).
#
# /etc/machine-id and /etc/ssh/ssh_host_* were stripped from the baked
# image so every flashed device gets unique identity. systemd-machine-id-setup
# and `ssh-keygen -A` are both natively idempotent (no-op if files exist),
# so even the conditional wrapping below is belt-and-suspenders.
# ---------------------------------------------------------------------------
step_regen_identity() {
    if [[ ! -s /etc/machine-id ]]; then
        log "step 4: regenerating /etc/machine-id"
        systemd-machine-id-setup || warn "step 4: systemd-machine-id-setup failed"
    else
        log "step 4: /etc/machine-id already populated; skipping"
    fi

    local existing
    existing=( /etc/ssh/ssh_host_*_key )
    if (( ${#existing[@]} > 0 )); then
        log "step 4: ssh host keys already present; skipping"
    else
        log "step 4: generating ssh host keys (ssh-keygen -A)"
        ssh-keygen -A || warn "step 4: ssh-keygen -A failed"
    fi
}

# ---------------------------------------------------------------------------
# Step 5: ensure systemd-timesyncd is enabled + running (F20).
#
# Pi 5 has no RTC battery by default; without NTP a fresh boot lands at
# epoch 0, breaking TLS handshakes against any backend with a recent cert.
# The unit was symlinked into sysinit.target.wants at image-build time
# (see customize_rootfs in assemble.sh) so this is belt-and-suspenders.
# Both `enable` and `start` are idempotent in systemd.
# ---------------------------------------------------------------------------
step_timesyncd() {
    if systemctl is-enabled systemd-timesyncd.service >/dev/null 2>&1; then
        log "step 5: systemd-timesyncd already enabled"
    else
        log "step 5: enabling systemd-timesyncd"
        systemctl enable systemd-timesyncd.service || warn "step 5: enable failed"
    fi

    if systemctl is-active systemd-timesyncd.service >/dev/null 2>&1; then
        log "step 5: systemd-timesyncd already running"
    else
        log "step 5: starting systemd-timesyncd"
        systemctl start systemd-timesyncd.service || warn "step 5: start failed"
    fi
}

# ---------------------------------------------------------------------------
# Step 6: write the informational breadcrumb to /data (NOT gating).
#
# We mount /data manually here (after step 1 created and step 2 grew it).
# ---------------------------------------------------------------------------
# Step 6: seed /data with /opt/agora/state and /opt/agora/persist content
# (bug os-bug-v002-state-on-rootfs).
#
# fstab on a v0.0.3+ image bind-mounts /data/agora/state -> /opt/agora/state
# and /data/agora/persist -> /opt/agora/persist so device identity, CMS
# pairing, the provisioned marker etc. survive an A/B slot flip. But on a
# fresh card those /data/agora/{state,persist} directories are empty seed
# dirs (step 1 created them but didn't populate them), and the rootfs slot
# carries any seed content shipped with the image plus anything written by
# package post-install scripts on first boot. We copy that into /data BEFORE
# local-fs.target activates the bind mounts. After the binds activate the
# rootfs dirs are masked and any further writes go to /data.
#
# Sentinel /data/.state-migrated makes this one-shot per card. We also
# short-circuit if the dirs are already mountpoints (shouldn't happen during
# firstboot since we run Before=local-fs.target, but belt-and-suspenders for
# the manual-re-run case).
# ---------------------------------------------------------------------------
step_state_migrate() {
    local sentinel="/data/.state-migrated"

    if ! mountpoint -q /data; then
        log "step 6: mounting /data for state migration"
        mkdir -p /data
        if ! mount /data 2>/dev/null; then
            warn "step 6: could not mount /data (fstab issue?); skipping state migration"
            return 0
        fi
    fi

    if [[ -f "$sentinel" ]]; then
        log "step 6: ${sentinel} present; state already migrated, skipping"
        return 0
    fi

    if mountpoint -q /opt/agora/state || mountpoint -q /opt/agora/persist; then
        log "step 6: /opt/agora/{state,persist} already a mountpoint; binds active before migration ran, just stamping sentinel"
        touch "$sentinel" 2>/dev/null || true
        return 0
    fi

    mkdir -p /data/agora/state /data/agora/persist
    chmod 0755 /data/agora/state /data/agora/persist

    if [[ -d /opt/agora/state ]]; then
        log "step 6: copying /opt/agora/state -> /data/agora/state"
        cp -a /opt/agora/state/. /data/agora/state/ 2>/dev/null || \
            warn "step 6: cp /opt/agora/state -> /data/agora/state returned non-zero; continuing"
    else
        log "step 6: /opt/agora/state not present in rootfs; skipping copy (just creating /data target)"
    fi

    if [[ -d /opt/agora/persist ]]; then
        log "step 6: copying /opt/agora/persist -> /data/agora/persist"
        cp -a /opt/agora/persist/. /data/agora/persist/ 2>/dev/null || \
            warn "step 6: cp /opt/agora/persist -> /data/agora/persist returned non-zero; continuing"
    else
        log "step 6: /opt/agora/persist not present in rootfs; skipping copy (just creating /data target)"
    fi

    sync
    touch "$sentinel" 2>/dev/null || true
    log "step 6: state migration complete, sentinel written"
}

# ---------------------------------------------------------------------------
# Step 7: write breadcrumb to /data marking firstboot complete on this card.
# Informational only — every step is idempotent and runs unconditionally;
# this is for human debugging / post-mortem.
#
# Mounting /data here is also a smoke test of fstab. If the breadcrumb path
# refuses to mount we want to know in the log even though the script returns
# 0 (per F5: firstboot is not gated on this).
#
# systemd's data.mount unit, scheduled for after our unit by local-fs.target,
# will recognize the existing mount via /proc/self/mountinfo and become a
# no-op.
# ---------------------------------------------------------------------------
step_breadcrumb() {
    local marker="/data/.firstboot-done"

    if ! mountpoint -q /data; then
        log "step 7: mounting /data to write breadcrumb"
        mkdir -p /data
        if ! mount /data 2>/dev/null; then
            warn "step 7: could not mount /data (fstab issue?); skipping breadcrumb"
            return 0
        fi
    fi

    if [[ ! -f "$marker" ]]; then
        date -Iseconds > "$marker" 2>/dev/null || true
        log "step 7: wrote breadcrumb to ${marker}"
    else
        log "step 7: breadcrumb already at ${marker} (firstboot has run on this card before)"
    fi
}

# ---------------------------------------------------------------------------
# Tail step: copy /run/agora-firstboot.log onto the FAT32 boot-A partition so
# a brick can be diagnosed from any host (Windows/macOS) by reading the boot
# partition without needing ext4 access. Best-effort — never fails the unit.
# ---------------------------------------------------------------------------
copy_log_to_boot() {
    local boot_dev boot_mnt
    boot_dev=$(blkid -L boot-A 2>/dev/null) || true
    if [[ -z "$boot_dev" ]]; then
        log "tail: PARTLABEL=boot-A not found; skipping log copy"
        return 0
    fi
    boot_mnt=$(mktemp -d /tmp/boot-firmware-log.XXXXXX) || return 0
    if mount -t vfat -o rw,sync "$boot_dev" "$boot_mnt" 2>/dev/null; then
        cp -f "$RUN_LOG" "${boot_mnt}/agora-firstboot.log" 2>/dev/null || true
        sync
        umount "$boot_mnt" 2>/dev/null || true
        log "tail: copied firstboot log to boot-A:/agora-firstboot.log"
    else
        warn "tail: could not mount boot-A for log copy; skipping"
    fi
    rmdir "$boot_mnt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
main() {
    log "starting (idempotent, no sentinel-gate per F5)"
    if ! preflight_tools; then
        err "preflight failed; aborting firstboot before destructive ops"
        copy_log_to_boot
        return 0
    fi
    step_layout_expand
    step_eeprom_floor
    step_regen_identity
    step_timesyncd
    step_state_migrate
    step_breadcrumb
    log "done"
    copy_log_to_boot
}

main "$@"

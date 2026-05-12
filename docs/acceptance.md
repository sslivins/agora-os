# Phase 0 acceptance checklist

This is a **runbook executed on hardware by a human**. The document is
the Phase 0 deliverable; the actual checks must be carried out by an
operator on a real Pi 5 holding a freshly-flashed SD card.

For the rationale behind each check, see the Phase 0 section of the
session plan (paths in this repo as of Phase 0: `image-build/` and
`pi-gen-overlay/stage-agora/`). The checks mirror the acceptance bullets
of that plan one-for-one.

## Prerequisites

- A tagged `agora-os` release. The release workflow has produced
  `agora-os-<tag>.img.zst` + `<tag>.img.zst.minisig` + `<tag>.img.zst.sha256`
  on the GitHub Release.
- A **32 GB or larger** SD card (D52 — the 5-partition layout occupies
  ~17 GB before `/data` is expanded).
- A Pi 5. For the v1.0.0 acceptance run, use the **oldest Pi 5 in
  stockroom** (F16, see `image-build/README.md` §5). For subsequent
  patch releases, any Pi 5 the operator has on hand is fine — the
  oldest-Pi check is for catching EEPROM-floor regressions and is
  needed only when the floor moves.
- USB SD-card writer (do not flash from inside the Pi being tested).
- A serial-console hookup, or SSH access. Some checks read journald
  and `vcgencmd` output.

## How to use this checklist

1. Work top-to-bottom. Each numbered check is independent in execution
   but the order matches the natural boot/inspect sequence.
2. Mark each check ✅ pass or ❌ fail in your release-notes draft.
3. **Any ❌ blocks promotion to lab ring.** Open an issue in
   `sslivins/agora-os`, paste the failing output, and re-cut the
   release. Do not rebuild the same tag.
4. The Phase 5 `signoff.md` will reference this run.

---

## Acceptance checks (Phase 0)

### A1. Build pipeline produces a release artifact (F19)

The CI workflow `.github/workflows/release.yml` runs to completion on
push of the release tag, on the `ubuntu-24.04-arm` runner (D55, no
qemu). The GitHub Release for the tag contains three attachments:

- `agora-os-<tag>.img.zst`
- `agora-os-<tag>.img.zst.minisig`
- `agora-os-<tag>.img.zst.sha256`

The release is created in **draft** state — that's fine; the
acceptance run takes it out of draft only after the checks pass.

### A2. Signature is from the primary key (D53)

On a build machine (or any Linux box with `minisign` installed):

```sh
minisign -V -P "$(cat image-build/update-pubkey.pem)" \
    -m agora-os-<tag>.img.zst \
    -x agora-os-<tag>.img.zst.minisig
```

Output must end with `Signature and comment signature verified`.
Also verify the SHA256:

```sh
sha256sum -c agora-os-<tag>.img.zst.sha256
```

### A3. Power-cycle (not soft reboot) into healthy slot A (F14)

Flash the image to the 32 GB+ SD card. Insert into the Pi 5. **Cold
boot** by applying power — EEPROM updates apply on power-cycle, not on
soft reboot.

Wait ~3 minutes. Confirm:

- `systemctl is-active agora-firstboot.service` → `inactive` (the
  oneshot completed).
- `systemctl is-active agora.service` → `active` (the main service is
  up).
- The current root is slot A:

  ```sh
  mount | grep ' on / '
  ```

  shows `/dev/mmcblk0p3` (or the equivalent `root-A` partition) mounted
  read-write.

### A4. Firstboot ran every step on first boot

`journalctl -u agora-firstboot.service -b` shows all of:

- Data-partition resize executed (or "already full, skipping" if you
  flashed onto a card where someone else pre-resized — for a fresh
  card the resize should actually run).
- EEPROM config applied or "already current."
- EEPROM floor applied or "already at floor."
- `/etc/machine-id` generated (F11).
- `/etc/ssh/ssh_host_*` generated (F11).
- `systemd-timesyncd` started (F20).

### A5. `/data` was expanded to fill the card

```sh
lsblk -bn -o NAME,SIZE /dev/mmcblk0
```

Partition 5 (`data`) size, in bytes, must be approximately
`total_card_size - 17 GiB`. For a 32 GB card that's ~15 GiB on the
data partition. The first-boot resize is one-shot and idempotent — a
second boot does not re-trigger it (see A12).

### A6. `/data/var-log/` bind-mount in place (D56)

```sh
ls -la /data/var-log/
findmnt /var/log
```

`/data/var-log/` exists and `/var/log` is bind-mounted to it from
`/etc/fstab`. Confirm the fstab line is present in both root slots
(`grep var-log /etc/fstab` on slot A, then mount slot B read-only and
check there too).

### A7. Per-device identity files are fresh (F11)

```sh
stat -c '%y' /etc/machine-id /etc/ssh/ssh_host_*
```

All timestamps are ≥ the boot time, not the image-build time.
`cat /etc/machine-id` returns 32 hex chars (not the all-zero
placeholder).

### A8. Time sync via timesyncd (F20)

```sh
timedatectl status
```

Within 5 minutes of boot, must show
`System clock synchronized: yes`. If the lab Pi has no internet, this
test is **deferred** to the in-network Pi rather than treated as a
fail — note the deferral.

### A9. EEPROM is at floor with the right config

```sh
vcgencmd bootloader_config
vcgencmd bootloader_version
```

- `bootloader_config` shows `NET_INSTALL_AT_POWER_ON=0` and
  `BOOT_ORDER=0xf461` (D54 / closes
  [`sslivins/agora#165`](https://github.com/sslivins/agora/issues/165)).
- `bootloader_version` shows a Unix timestamp ≥ the value in
  `image-build/eeprom-floor.txt`.

### A10. All 5 GPT partitions with correct names (D51)

```sh
sudo sgdisk -p /dev/mmcblk0
```

Lists exactly 5 partitions with labels:

| # | label | filesystem |
|---|---|---|
| 1 | `boot-A` | vfat |
| 2 | `boot-B` | vfat |
| 3 | `root-A` | ext4 |
| 4 | `root-B` | ext4 |
| 5 | `data` | ext4 |

Confirm `/dev/disk/by-partlabel/root-A`, `root-B`, and `data` exist as
symlinks.

### A11. Slot B mirror is structurally identical (D57, read-write)

```sh
sudo mkdir -p /mnt/root-b
sudo mount /dev/disk/by-partlabel/root-B /mnt/root-b
diff -rq / /mnt/root-b \
    --exclude=proc --exclude=sys --exclude=dev --exclude=run \
    --exclude=tmp --exclude=data --exclude=boot
```

The only expected differences are:

- `/etc/fstab` — slot B's references `root-B`'s boot partition.
- `/etc/cmdline.txt` location differences inside `/boot/firmware/` —
  but you excluded `/boot` from the diff above, so this doesn't show.

Confirm slot B is mountable **read-write** (not RO per D57):

```sh
sudo mount -o remount,rw /mnt/root-b
sudo touch /mnt/root-b/tmp/.test-rw && sudo rm /mnt/root-b/tmp/.test-rw
```

Unmount:

```sh
sudo umount /mnt/root-b
```

### A12. Both root slots have the var-log fstab line (D56)

```sh
sudo mount /dev/disk/by-partlabel/root-B /mnt/root-b
grep var-log /mnt/root-b/etc/fstab  # bind mount line present
grep var-log /etc/fstab             # slot A also
sudo umount /mnt/root-b
```

### A13. Per-slot cmdline.txt uses PARTLABEL (D51, F15)

```sh
sudo mount /dev/disk/by-partlabel/boot-A /mnt/boot-a
sudo mount /dev/disk/by-partlabel/boot-B /mnt/boot-b
cat /mnt/boot-a/cmdline.txt   # contains 'root=PARTLABEL=root-A'
cat /mnt/boot-b/cmdline.txt   # contains 'root=PARTLABEL=root-B'
sudo umount /mnt/boot-a /mnt/boot-b
```

The cmdline files live under `/boot/firmware/` on the live mount and
at the root of each boot partition when mounted standalone (F15).

### A14. `autoboot.txt` mirrored on both boot partitions (F6)

```sh
sudo mount /dev/disk/by-partlabel/boot-A /mnt/boot-a
sudo mount /dev/disk/by-partlabel/boot-B /mnt/boot-b
diff /mnt/boot-a/autoboot.txt /mnt/boot-b/autoboot.txt
# (no output = byte-identical)
sudo umount /mnt/boot-a /mnt/boot-b
```

Single point of failure on `boot-A` integrity is eliminated by this
mirror.

### A15. Both signing pubkeys baked into both root slots (D54)

```sh
test -f /etc/agora/update-pubkey.pem
test -f /etc/agora/update-pubkey-recovery.pem

sudo mount /dev/disk/by-partlabel/root-B /mnt/root-b
test -f /mnt/root-b/etc/agora/update-pubkey.pem
test -f /mnt/root-b/etc/agora/update-pubkey-recovery.pem
sudo umount /mnt/root-b
```

The pubkeys are byte-identical to `image-build/update-pubkey.pem` and
`image-build/update-pubkey-recovery.pem` in the repo (cmp them if you
want to be paranoid).

### A16. Idempotency — second boot is quiet (F5)

```sh
sudo reboot
# wait for it
ssh pi@<host>
journalctl -u agora-firstboot.service -b
```

Every step short-circuits with its "already done" branch. No reformats,
no key regenerations, no EEPROM rewrites. The whole service unit goes
green in <10 seconds.

### A17. Idempotency — `dd`-cloned card also boots cleanly (F5)

This is the harder idempotency case. Flash the **already-booted-once**
card to a second SD card via raw `dd`:

```sh
sudo dd if=/dev/mmcblk0 of=cloned.img bs=4M status=progress
# burn cloned.img to a fresh SD card
```

Boot the cloned card on a different Pi 5. Verify:

- `agora-firstboot.service` ran (the resize step fires because the
  cloned card may be a different size).
- `/etc/machine-id` on the cloned card is **different** from the
  original (the firstboot detects the duplicate and regenerates per
  F11 — but only if the implementation actually checks for "already
  seen this machine-id on the network"; for v1 we accept that
  identical machine-ids on dd-cloned cards is a known limitation and
  log a warning).

For v1, this check is **informational only** — pass means "the cloned
card boots and runs"; the machine-id deduplication is a follow-up.

### A18. Tryboot sanity check (F13)

This is the killer check — it confirms that slot B is actually
bootable, not just present.

```sh
# Hand-rsync slot A's content into slot B.
sudo mount /dev/disk/by-partlabel/root-B /mnt/root-b
sudo rsync -aAX --delete --exclude='/etc/fstab' / /mnt/root-b/
# Keep slot B's fstab — it has the right boot-partition reference.
sudo umount /mnt/root-b

# Reboot into tryboot, which selects slot B per autoboot.txt.
sudo vcgencmd reboot_to_tryboot
sudo reboot
```

After tryboot:

- Pi comes up healthy on slot B (`mount | grep ' on /'` shows
  `root-B`).
- `systemctl is-active agora.service` → `active`.
- The autoboot mechanism returned to slot A on the **next** plain
  reboot — tryboot is a one-shot:

  ```sh
  sudo reboot
  # after the reboot:
  mount | grep ' on / '  # back on root-A
  ```

This confirms the slot-B half of the image is actually bootable and
that tryboot revert works (Phase 1 will automate the revert, but in
Phase 0 we just want to know the bytes are right).

### A19. Stockroom-Pi smoke-test (F16, first release of each major line)

If this is `v1.0.0` (or any release that bumps the EEPROM floor): all
of A1-A18 must have been performed on the **oldest Pi 5 in stockroom**
specifically. Document the Pi's serial number in the release notes.

If this is a patch release (e.g. `v1.0.4`) and the EEPROM floor hasn't
moved, the stockroom check can be skipped — perform A1-A18 on any
on-hand Pi 5.

---

## Sign-off

When all checks pass, paste the following into the GitHub Release
notes for the tag:

```markdown
## Phase 0 acceptance (executed by <name> on <date>)

Pi 5 serial: `<serial>` (oldest in stockroom: yes/no)
SD card size: <e.g. 32 GB>
EEPROM floor: `<value from eeprom-floor.txt>`

✅ A1  Release artifact present (`.img.zst` + `.minisig` + `.sha256`)
✅ A2  Signature verifies against primary pubkey
✅ A3  Cold-boot into healthy slot A
✅ A4  Firstboot ran every step
✅ A5  `/data` expanded to fill card
✅ A6  `/var/log` bind-mounted to `/data/var-log/`
✅ A7  `/etc/machine-id` and SSH host keys are fresh
✅ A8  timesyncd synchronized within 5 min
✅ A9  EEPROM at floor, `NET_INSTALL_AT_POWER_ON=0`, `BOOT_ORDER=0xf461`
✅ A10 All 5 GPT partitions with correct labels
✅ A11 Slot B mounts read-write and matches slot A structurally
✅ A12 Both root slots have var-log fstab line
✅ A13 Per-slot cmdline.txt uses PARTLABEL
✅ A14 autoboot.txt mirrored on both boot partitions
✅ A15 Both pubkeys baked into both root slots
✅ A16 Second boot is quiet (idempotent)
✅ A17 dd-cloned card boots cleanly (informational for v1)
✅ A18 Tryboot to slot B + revert works
✅ A19 Stockroom-Pi smoke-test (or N/A for patch release)
```

Then take the release out of draft and publish.

If any check is ❌, do not publish. Open an issue in
`sslivins/agora-os`, paste the failing check + output, and re-cut the
release with the fix.

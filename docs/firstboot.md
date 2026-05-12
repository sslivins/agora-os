# agora-firstboot.service

Runs once on every boot (idempotently). Lives at
`/etc/systemd/system/agora-firstboot.service`, script at
`/usr/local/sbin/agora-firstboot`.

## Why "no sentinel gate"

A naive firstboot drops a file like `/var/firstboot-done` and the unit
exits early on subsequent boots. That looks tidy but breaks two real
scenarios:

1. **dd-cloning the SD card to a fresh card.** The sentinel file
   carries over, so the new card never grows its data partition to fill
   itself.
2. **Replacing an SD card from a known-good image.** Same problem.

So instead, every step is **internally idempotent** — it checks its
own post-condition (partition already at 100%, machine-id already set,
EEPROM already at floor, etc.) and short-circuits. On steady-state
boots the unit takes a second or two and produces a handful of "already
done; skipping" log lines. (See F5 in the Phase 0 plan.)

The `/data/.firstboot-done` breadcrumb is informational only — useful
when you `journalctl -u agora-firstboot` and want to know whether this
card has ever booted before, but it does NOT gate any step.

## Steps

| # | What | Idempotency | Reference |
|---|------|-------------|-----------|
| 1 | Grow partition 5 (PARTLABEL=data) + resize2fs | parted resizepart 100% is a no-op when already at 100%; resize2fs prints "Nothing to do" | F8 |
| 2 | Apply pinned EEPROM floor if current < floor | timestamp comparison against `/boot/firmware/agora-eeprom-floor.txt` | F9, F14 |
| 3 | Generate `/etc/machine-id` + `/etc/ssh/ssh_host_*` if missing | `systemd-machine-id-setup` and `ssh-keygen -A` only generate missing files | F11 |
| 4 | Enable + start `systemd-timesyncd` | `systemctl enable/start` are idempotent | F20 |
| 5 | Write `/data/.firstboot-done` breadcrumb | mount /data manually, write timestamp if absent | informational |

## Unit ordering

The unit runs in the window between `local-fs-pre.target` and
`local-fs.target`, which is **before** `/etc/fstab` is processed. That
ordering is what makes step 1 safe (we resize partition 5 while /data
is unmounted).

```
[Unit]
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target

[Install]
WantedBy=local-fs.target
```

Note that `WantedBy=sysinit.target` would NOT work — `sysinit.target`
runs after `local-fs.target` has already mounted everything from fstab.

## Failure modes

* **Step 1 fails** (parted or resize2fs errors): logged, unit continues.
  `/data` will mount at ship size (~1 GB). The device boots and runs;
  next reboot retries the resize.
* **Step 2 fails** (rpi-eeprom-update errors): logged, unit continues.
  EEPROM stays at whatever it currently is. The Pi continues to boot.
  Re-runs on next boot.
* **Step 3 fails** (systemd-machine-id-setup or ssh-keygen failure):
  rare; logged, unit continues. systemd auto-generates machine-id on
  next boot if still empty.
* **Step 4 fails** (timesyncd enable/start): boot continues. The unit
  is already enabled in `sysinit.target.wants` at image-build time, so
  this step is belt-and-suspenders.
* **Step 5 fails** (couldn't mount /data): no breadcrumb. Cosmetic.

The unit itself uses `Type=oneshot` + `RemainAfterExit=yes`, so a clean
exit means systemd marks it active forever. Downstream units (e.g.,
`agora.service`) should declare `Wants=agora-firstboot.service` (soft
dep) rather than `Requires=` so a step-1 failure doesn't prevent the
device from coming up.

## Acceptance

See the `p0-acceptance` todo in `plan.md` for the full power-on-fresh-card
checklist. Two firstboot-specific items:

* First boot: `lsblk` shows partition 5 expanded to fill the card;
  `/etc/machine-id` and `/etc/ssh/ssh_host_*` are populated; `timedatectl
  status` shows synchronized=yes within 5 min.
* Second boot (reboot, same card): `journalctl -u agora-firstboot` shows
  every step skipping with "already done" log lines and no errors.
* Dd-clone test: `dd` the booted-once card to a fresh card, boot the
  fresh card, observe firstboot does its full work again on the clone.

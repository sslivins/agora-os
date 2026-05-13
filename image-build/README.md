# `image-build/` — agora-os image build runbook

This document is the operator manual for the `agora-os` image build:
prereqs, the local-build invocation, the signing-key custody ceremony
(primary + recovery per D54), the GitHub branch-protection setup, the
stockroom-Pi smoke-test ritual (F16), the EEPROM floor pin procedure,
and the rootfs ↔ agora-app version-coordination story (F17, Decision #2).

The corresponding CI build is in
[`../.github/workflows/release.yml`](../.github/workflows/release.yml).
That workflow does everything this README describes (clone pi-gen, copy
the overlay, split the output, call `assemble.sh`, sign, attach to a
draft release). Tagged releases are the supported path; local builds are
for development and the stockroom smoke-test only.

---

## 1. Prerequisites

The build runs on Linux (Ubuntu 24.04+ recommended; matches the CI runner
per D55). macOS and Windows are not supported — the build mounts ext4 and
runs `losetup --partscan`. Inside WSL2 works *only* if your kernel exposes
`/dev/loop*`; native Linux is the supported path.

Root is required (loop mounts, `mkfs`, `sgdisk`).

Install the toolchain:

```sh
sudo apt-get update
sudo apt-get install -y \
    build-essential debootstrap qemu-user-static \
    coreutils util-linux dosfstools e2fsprogs gdisk parted \
    xz-utils minisign rsync ca-certificates curl git \
    rpi-eeprom
```

Free disk on the build host: **at least 12 GB**. The assembled image
ships only 2 partitions (`boot-A` 512 MB + `root-A` 3 GB ≈ ~3.5 GB raw)
before xz -T0 -9 brings it down to ~500–700 MB. On-device firstboot
expands this to the full 5-partition layout (adds `boot-B`, `root-B`,
`data`; grows `root-A` to 8 GB) — see §1.1 below. The intermediate
pi-gen build directory adds another ~6 GB.

Flash time on a typical USB 2.0 SD writer: **~3 minutes** for the
shrunken ship image, vs ~15 minutes for the prior full-5-partition
image. First-boot expansion adds ~30 seconds on top before
`agora.service` comes up.

### 1.1 Ship layout vs runtime layout

The image you flash is **not** the layout the running device sees.

| Phase            | Partitions on disk                                    |
|------------------|-------------------------------------------------------|
| Flash (ship)     | `boot-A` (512 MB) + `root-A` (3 GB)                  |
| After firstboot  | `boot-A` + `root-A` (8 GB) + `boot-B` + `root-B` + `data` (rest of card) |

`agora-firstboot.service` (`firstboot/agora-firstboot.sh`, step
`layout_expand`) is the only thing that performs this expansion. It is
idempotent: a second boot detects that `data` already exists by
`PARTLABEL` and short-circuits.

The 5-partition layout described in the rest of this README, in
`README.md`, and in `docs/acceptance.md` is the **runtime** layout. All
acceptance checks (A4 onward) run **after** first-boot has completed.

Required to flash to a real Pi 5 for the stockroom smoke-test (§5):

- **SD card: 32 GB minimum**. The data partition resizes to fill the
  card on first boot, so a 64 GB card just means a bigger `/data` —
  there's no benefit beyond ~32 GB unless you intend to use the extra
  space.
- A USB SD-card writer (built-in slots are fine; just don't use the
  Pi's own slot to flash itself).

---

## 2. Local build (development)

For day-to-day rootfs hacking — change a file in `pi-gen-overlay/`,
build, flash, test:

```sh
# 1. Clone pi-gen pinned to the same SHA the release workflow uses.
#    Check .github/workflows/release.yml for the current pin.
git clone https://github.com/RPi-Distro/pi-gen.git ../pi-gen
cd ../pi-gen
git checkout <pinned-sha>
cd -

# 2. Stage the agora overlay as pi-gen's export stage.
cp -r pi-gen-overlay/stage-agora ../pi-gen/stage-agora
touch ../pi-gen/stage-agora/EXPORT_IMAGE
touch ../pi-gen/stage3/SKIP ../pi-gen/stage3/SKIP_IMAGES
touch ../pi-gen/stage4/SKIP ../pi-gen/stage4/SKIP_IMAGES
touch ../pi-gen/stage5/SKIP ../pi-gen/stage5/SKIP_IMAGES

# 3. Write pi-gen config.
cat > ../pi-gen/config <<'EOF'
IMG_NAME='agora-os-base'
RELEASE='bookworm'
STAGE_LIST='stage0 stage1 stage2 stage-agora'
DEPLOY_COMPRESSION='none'
EOF

# 4. Build the base rootfs + boot tarballs.
(cd ../pi-gen && sudo ./build.sh)

# 5. Loop-mount pi-gen's output and split it into the two tarballs
#    assemble.sh expects.
IMG=../pi-gen/deploy/agora-os-base-*.img
LOOP=$(sudo losetup --show -f --partscan "$IMG")
mkdir -p /tmp/boot /tmp/root
sudo mount "${LOOP}p1" /tmp/boot
sudo mount "${LOOP}p2" /tmp/root
sudo tar -C /tmp/boot -cf out/boot.tar .
sudo tar -C /tmp/root --exclude='./boot/firmware/*' -cf out/rootfs.tar .
sudo umount /tmp/boot /tmp/root
sudo losetup -d "$LOOP"

# 6. Assemble the 5-partition image.
sudo ./image-build/assemble.sh out/rootfs.tar out/boot.tar dist/agora-os-dev.img.xz

# 7. (Optional) Sign locally for testing. NEVER commit the .key file.
#    Use a throwaway dev key, not your production keypair.
minisign -S -W -s ~/agora-dev.key -t "agora-os dev local build" \
    -m dist/agora-os-dev.img.xz
```

The output `agora-os-dev.img.xz` can be flashed with `rpi-imager`,
`dd`, or `gnome-disks` — anything that handles xz-compressed
filesystem images. Target a 32 GB+ SD card.

For the **release** path (tag-driven CI build), skip all of this — just
push a tag and the workflow does it. See §3.

---

## 3. Release path (CI-driven, the supported path)

Cutting a release is one operation: tag and push.

```sh
git tag v1.0.0
git push origin v1.0.0
```

That triggers `.github/workflows/release.yml`. The job:

1. Clones pi-gen at the pinned SHA.
2. Stages the overlay (same as §2 steps 2–4).
3. Builds, splits, assembles (same as §2 steps 5–6).
4. Signs `agora-os-<tag>.img.xz` with `minisign` using `MINISIGN_SECRET`
   (the GitHub Actions secret, see §4).
5. Drafts a GitHub Release with `.img.xz` + `.minisig` + `.sha256`
   attached.

After the workflow finishes, edit the draft release notes, then publish.
The published release is the artifact CMS dispatches via the Phase 2
update bundle path (see the `os-updates.md` architecture doc in Phase 5).

---

## 4. Signing-key custody (D54: two keys, hot + cold)

The image and every OTA bundle (Phase 2) are signed with
[minisign](https://jedisct1.github.io/minisign/), an Ed25519 signer.
Per D54, **two** keypairs exist; both pubkeys are baked into the rootfs
at `/etc/agora/update-pubkey.pem` (primary) and
`/etc/agora/update-pubkey-recovery.pem` (recovery). The on-device
verifier accepts a signature from either. This is the **only**
opportunity to bake a recovery key — it cannot be retrofitted to
deployed devices.

### 4.1 Generate the primary keypair (one time, offline)

Do this on a Linux machine that is **not** your daily driver: ideally an
air-gapped laptop, a fresh live USB, or at minimum a machine you'd
otherwise burn for sensitive credentials. Do **not** generate the key
on a CI runner or in a cloud VM.

```sh
# On the offline machine:
minisign -G -W \
    -p agora-os-primary-pubkey.pem \
    -s agora-os-primary.key

# -W = no password on the private key (required for CI use).
#      The protection comes from secret-storage, not a passphrase.
```

Output:
- `agora-os-primary-pubkey.pem` — short, public, copy into the repo.
- `agora-os-primary.key` — secret, never leaves the offline machine
  except in the secure channels below.

**Commit the public key** to the repo:

```sh
cp agora-os-primary-pubkey.pem image-build/update-pubkey.pem
git add image-build/update-pubkey.pem
git commit -m "Bake primary signing pubkey (one-time, irrevocable for fielded devices)"
```

`assemble.sh` copies that file into `/etc/agora/update-pubkey.pem` of
both root slots.

**Store the private key in three places** (all three required; losing
the key invalidates fleet recovery without the recovery key):

1. **GitHub Actions secret `MINISIGN_SECRET`**:
   - GitHub → Settings → Secrets and variables → Actions → New
     repository secret.
   - Name: `MINISIGN_SECRET`. Value: full contents of
     `agora-os-primary.key` (`untrusted comment:` line and all).
2. **1Password vault** "agora-ops" → item "agora-os primary signing
   key". Attach the `.key` file. Tag: `do-not-rotate-without-runbook`.
3. **Paper backup** in the office safe. Print with reasonable margins.
   Label "agora-os primary signing key — DO NOT scan, DO NOT photograph,
   DO NOT type into anything online. Burn before discarding."

### 4.2 Generate the recovery keypair (D54)

Same procedure as §4.1, but for the recovery key:

```sh
minisign -G -W \
    -p agora-os-recovery-pubkey.pem \
    -s agora-os-recovery.key
```

**Commit the public key** as
`image-build/update-pubkey-recovery.pem`. `assemble.sh` copies it to
`/etc/agora/update-pubkey-recovery.pem` of both root slots.

**The recovery private key is cold storage. It is never on a hot
machine:**

- **Paper backup #1**: office safe. Same handling as the primary
  paper backup. Sealed envelope, signed across the seal.
- **Paper backup #2 (encrypted)**: encrypted with a GPG passphrase
  known only to the engineering lead, stored in a *different* physical
  location from the office safe (e.g. owner's home safe, bank deposit
  box). The passphrase itself is recorded in 1Password under a
  separate item with explicit access logging.
- **No GitHub Actions secret. No 1Password attachment of the raw key.**

The recovery key is used **only** in the ceremony described in §4.4. If
you ever find yourself reaching for it for any other reason, stop and
re-read this section.

### 4.3 Routine signing (normal flow, automated)

You should never invoke `minisign` by hand for production builds. The
release workflow does it: pulls `MINISIGN_SECRET` from Actions secrets,
writes it to a tmpfs file with `umask 077`, calls
`minisign -S -W -s $KEY_FILE -t "agora-os <tag>" -m <img>` once for the
`.img.xz` and once for the OTA bundle `.tar.zst` (Phase 2), then shreds
the keyfile. The key never lands on disk outside that ephemeral path.

Both artifacts are signed with the **primary** keypair. Devices verify
the OTA bundle against `/etc/agora/update-pubkey.pem` baked into their
rootfs by `assemble.sh`, so the keypair sitting in `MINISIGN_SECRET`
*must* match the pubkey committed at `image-build/update-pubkey.pem`.

A mismatch is silent and catastrophic in production — every OTA in the
fleet fails with a generic "bad signature" that's painful to debug
from telemetry alone. To prevent that class of bug, the release
workflow runs a **smoke-test step** after signing: it calls
`minisign -V -p image-build/update-pubkey.pem -m <artifact>` against
both the signed image and the signed bundle. If either fails to
verify against the committed pubkey, the release is not cut. The cost
is a few seconds per release; the upside is that a `MINISIGN_SECRET`
↔ pubkey desync is caught before any device ever sees it.

If the smoke-test ever fails, **do not "fix" by rotating either
side without thinking**. The likely failure modes are: (a) someone
edited `MINISIGN_SECRET` without updating the committed pubkey
(rotate the secret back, or run the rotation ceremony in §4.4); or
(b) `image-build/update-pubkey.pem` was overwritten in a PR (revert
the PR, never rotate to match a corrupted pubkey). Rotating the
production keypair is a §4.4 ceremony — never a CI fix-up.

### 4.4 Recovery ceremony (D54, break-glass)

You only run this if the primary key is **confirmed compromised** —
i.e. someone outside the trust circle has obtained
`agora-os-primary.key`. A *lost* primary key without compromise is a
different procedure: you generate a new primary, ship a new release
signed by the recovery key as a one-time "rotate the new primary in,"
and then go back to the primary.

Full ceremony:

1. **Convene** the engineering lead + at least one other ops-trusted
   person. Two-person rule.
2. **Document** the compromise event in an internal incident note
   before touching anything: when discovered, how, what mitigations
   are in place.
3. **Retrieve** the recovery paper backup from the office safe. Witness
   present.
4. **Type** (don't OCR, don't photograph) the key contents into a fresh
   live-USB Linux session on a known-good laptop. Verify the resulting
   file matches the second paper backup by computing
   `sha256sum agora-os-recovery.key` and comparing against the digest
   recorded at generation time. (Record this digest in 1Password at
   generation time. If you didn't — generate a *new* recovery key now,
   re-bake on next release.)
5. **Generate a new primary keypair** per §4.1.
6. **Commit the new primary pubkey** to the repo at
   `image-build/update-pubkey.pem` (overwriting the compromised one).
   The recovery pubkey stays where it is.
7. **Cut a one-off release** signed with the **recovery** key, not the
   new primary:

   ```sh
   # Run from the live USB session, key still in memory.
   minisign -S -W -s agora-os-recovery.key \
       -t "agora-os recovery-cut <tag> — primary key rotation" \
       -m agora-os-<tag>.img.xz
   ```

   Bake the new primary pubkey into this image. On-device verifiers
   accept the recovery signature, install the image, and the new
   primary pubkey rolls out to the fleet.
8. **Shred** the recovery key copy on the live USB (`shred -uvz` on
   the file, then unmount and physically wipe the USB).
9. **Cut the next release** signed by the **new primary** to confirm
   the fleet works on the rotated key.
10. **Update** the GH Actions secret `MINISIGN_SECRET` with the new
    primary `.key` contents.
11. **Re-store** the new primary key per §4.1 (1Password + paper).
12. **Audit-log** the entire ceremony in the incident note: who, when,
    artifact hashes of the recovery-signed release, time the new primary
    became active.

This is the **only** time the recovery key touches a machine. If you
run this ceremony, treat the recovery key as expended afterward —
generate a new recovery keypair on the next major release (D54 explicitly
contemplates this: it's a one-shot key per use).

---

## 5. Stockroom-Pi smoke test (F16, mandatory before lab ring)

A v1.0.0 build is **not eligible** for promotion to the lab ring until
it has booted cleanly on the oldest Pi 5 in stockroom. This catches
firmware-floor mismatches and slot-B latent issues before they hit any
device that's wired to power-cycle remotely.

Checklist for each new tagged image:

1. Pull a Pi 5 from stockroom — pick the **oldest** one available (look
   for the earliest serial number, or pull the unit that's been on the
   shelf longest). Goal: catch EEPROM-floor regressions on units that
   haven't received recent OTA EEPROM updates.
2. Fully wipe a 32 GB+ SD card (zero the first 8 MB to clear any prior
   GPT: `sudo dd if=/dev/zero of=/dev/sdX bs=1M count=8 conv=fsync`).
3. Flash `agora-os-<tag>.img.xz` (from the draft GitHub Release) to
   the card.
4. Insert into the stockroom Pi, **power-cycle** (cold boot, not soft
   reboot — EEPROM updates apply only on power-cycle, F14).
5. Wait 5 minutes. Run the Phase 0 acceptance battery (see
   [`../docs/acceptance.md`](../docs/acceptance.md)):
   - `lsblk` shows 5 partitions including a `data` partition resized
     to fill the card.
   - `/data/var-log/` exists and `/var/log` is bind-mounted to it.
   - `/etc/machine-id` and `/etc/ssh/ssh_host_*` are present and look
     freshly generated (timestamp ~boot time).
   - `timedatectl status` reports `System clock synchronized: yes`.
   - `vcgencmd bootloader_config` shows `NET_INSTALL_AT_POWER_ON=0`
     and `BOOT_ORDER=0xf461`.
   - Reboot again → `journalctl -u agora-firstboot.service -b` shows
     every step short-circuited (the idempotency check).
6. **Tryboot sanity** (F13): hand-rsync the running root content into
   `root-B`, then:

   ```sh
   sudo vcgencmd reboot_to_tryboot && sudo reboot
   ```

   After tryboot the Pi must come up on slot B; agora.service runs.
   Run `mount | grep ' on / '` and confirm `root-B` is the active
   root partition.

If any check fails, the build is **blocked** from promotion. Open an
issue in `sslivins/agora-os`, attach the failing log excerpt, and
treat the tag as cursed. Do not rebuild the same tag — bump and re-cut.

When all checks pass, attach the resulting log as a release-notes
section ("Stockroom smoke-test passed on Pi 5 serial <N> at <date>")
and publish the release.

---

## 6. Pinning the EEPROM floor (`eeprom-floor.txt`)

`image-build/eeprom-floor.txt` holds the **minimum acceptable bootloader
timestamp** — a Unix epoch integer. On first boot, `agora-firstboot.sh`
compares the running EEPROM's `BUILD_TIMESTAMP` against this floor and,
if behind, applies the bundled `rpi-eeprom-update` artifact.

Floor pinning procedure (do this exactly once per major release, e.g.
once per v1.x.x line):

1. Make sure the stockroom Pi has booted onto the candidate release
   image and that `agora-firstboot.service` ran the floor application
   successfully (`vcgencmd bootloader_version`).
2. Power-cycle. The EEPROM update takes effect on next power-on (F14).
3. After the power-cycle:

   ```sh
   vcgencmd bootloader_version | grep -oP '(?<=^)[0-9]{10,}' | head -n1
   ```

   That's the timestamp value of the now-installed bootloader.
4. Write that exact integer (no whitespace, no newline noise) to
   `image-build/eeprom-floor.txt`:

   ```sh
   echo 1234567890 > image-build/eeprom-floor.txt
   ```

   Keep the comment header (it documents the format).
5. Commit:

   ```sh
   git commit -m "Pin EEPROM floor to <date> bootloader for v1.0.0"
   ```

6. Rebuild the release. The new image's firstboot will now refuse to
   accept any EEPROM older than this floor.

The floor is **monotonic**. Never lower it across releases without
explicit operator sign-off — that would re-enable EEPROM downgrades
on devices that previously upgraded.

---

## 7. Branch protection (D53, manual setup)

The release workflow is the only thing that holds the production
signing key. Branch protection on the workflow itself prevents a rogue
contributor from modifying it to exfiltrate `MINISIGN_SECRET`.

This **cannot** be configured via the GH Actions secret model and
**cannot** be applied by this repo automatically. An admin must set it
up by hand:

1. Go to **Settings → Branches** on `sslivins/agora-os`.
2. Add a branch protection rule for `main`.
3. Enable:
   - ✅ Require a pull request before merging.
   - ✅ Require status checks to pass (`build` from the release
     workflow, once it's run at least once).
   - ✅ Restrict who can push to matching branches → owners + named
     maintainers only.
4. **Critical**: Add a path-based protection (Settings → Code security
   → Path-based rules, or via CODEOWNERS):
   - Pattern: `.github/workflows/*`.
   - Restrict to: org owner + engineering lead only.
   - Require PR review from the listed owners.
5. Re-verify after every org-membership change.

If your GH plan doesn't expose path-based rules (Free/Pro), use
`CODEOWNERS` to require a named reviewer for any workflow file change,
and combine with branch protection's "require review from code owners"
checkbox.

---

## 8. Rootfs ↔ agora-app version coordination (F17, Decision #2)

The rootfs and the application it runs are independent release trains
with explicit floor handshakes:

- The rootfs declares a **minimum supported agora-app version** in
  `/etc/agora/version`:

  ```ini
  rootfs_version=v1.0.0
  agora_app_floor=v2.4.0
  ```

  `agora_app_floor` is the oldest agora-app this rootfs will allow to
  run. If a fielded device has an older agora-app at boot, the CMS-side
  pre-flight refuses the OS update until the app is upgraded first.

- The agora-app declares a **minimum required rootfs** in its release
  metadata (`requires_rootfs: ">=v1.0.0"`). If a device is on an older
  rootfs, the CMS refuses to push that agora-app update.

This is enforced **on the CMS** before any bundle dispatch (Phase 2).
The on-device code is intentionally permissive — it doesn't try to
re-validate, because the CMS is the source of truth and a misbehaving
device would just get stuck.

When cutting an `agora-os` release that bumps `agora_app_floor`:

1. Coordinate with the agora-app team: the floor you're setting must
   already be a published agora-app release.
2. Edit `image-build/assemble.sh` (or wherever `assemble.sh` writes
   `/etc/agora/version`) to set the new floor.
3. Roll the OS to `lab` first, then storeA, per the standard ring
   sequence. Devices that haven't yet upgraded their agora-app to the
   new floor will refuse to install until they do — this is intentional
   and matches the contract.

---

## 9. Files in this directory

| File | Purpose |
|---|---|
| `assemble.sh` | The **2-partition** ship-image assembler (D55). Reads `rootfs.tar` + `boot.tar`, produces a signed-elsewhere `.img.xz`. Firstboot expands to the runtime 5-partition layout — see §1.1. |
| `partition.sh` | `sgdisk` helper that lays down the **ship** GPT: `boot-A` + `root-A` only. |
| `eeprom-floor.txt` | Bootloader-timestamp floor (Unix epoch). Pinned per major release per §6. |
| `eeprom-config.template` | The `BOOT_ORDER` / `NET_INSTALL_AT_POWER_ON` / `BOOT_UART` config baked into both `boot-A` and `boot-B` (F6 mirror) and re-applied by firstboot if drifted (D54 / F9 two-operation bring-up). |
| `firstboot/agora-firstboot.sh` | On-device firstboot orchestrator (idempotent per F5). Resizes `/data`, applies EEPROM floor, generates `/etc/machine-id` + SSH host keys (F11), starts `systemd-timesyncd` (F20). |
| `firstboot/agora-firstboot.service` | The systemd oneshot unit that runs `agora-firstboot.sh` before `agora.service`. |
| `update-pubkey.pem` | Primary signing pubkey, baked into `/etc/agora/update-pubkey.pem` of both root slots (D54). |
| `update-pubkey-recovery.pem` | Recovery signing pubkey, baked into `/etc/agora/update-pubkey-recovery.pem` (D54). Only used in the §4.4 ceremony. |
| `README.md` | This file. |

---

## See also

- [`../docs/eeprom-recovery.md`](../docs/eeprom-recovery.md) — what to do
  when a device cannot complete a BOOT_ORDER cycle and falls into
  `0xf461`'s USB-mass-storage recovery path.
- [`../docs/acceptance.md`](../docs/acceptance.md) — the Phase 0
  acceptance checklist this README's smoke-test step refers to.
- The plan in the architecture doc (Phase 5: `os-updates.md`) for how
  this image fits into the full OS-update story.

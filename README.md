# agora-os

Build pipeline for the Agora Pi 5 OS image — a 5-partition GPT layout supporting
A/B rootfs OTA updates plus a persistent data slot.

Status: Phase 0 scaffold. The build is not yet wired end-to-end. See
[`agora-cms#544`](https://github.com/sslivins/agora-cms/issues/544) for the
parent design and [`agora-cms#549`](https://github.com/sslivins/agora-cms/issues/549)
for the ring-rollout sibling.

## Partition layout

| # | GPT name | FS    | Size  | Purpose                                       |
|---|----------|-------|-------|-----------------------------------------------|
| 1 | boot-A   | FAT32 | 512 MB| Pi 5 firmware + kernel + cmdline (slot A)     |
| 2 | boot-B   | FAT32 | 512 MB| Slot B equivalent                             |
| 3 | root-A   | ext4  | 8 GB  | Rootfs slot A (RW per D57)                    |
| 4 | root-B   | ext4  | 8 GB  | Rootfs slot B (RW per D57)                    |
| 5 | data     | ext4  | rest  | Persistent: `/data`, `/var/log` bind-mount    |

The kernel selects its slot via `root=PARTLABEL=root-A|root-B` (D51). Tryboot
switches via `vcgencmd reboot_to_tryboot` and `autoboot.txt` (mirrored to both
boot partitions per F6 so boot-A is not a SPOF).

Target SD floor: 32 GB (D52). The image ships at ~18 GB; the `data` partition
auto-expands to fill the rest on first boot.

## Repo layout

```
.
├── image-build/                # build scripts and templates
│   ├── assemble.sh             # main assembler: pi-gen tarballs → .img.xz
│   ├── partition.sh            # sgdisk helper for the 5-part GPT
│   ├── autoboot.txt            # tryboot config — same file on both boot parts (F6)
│   ├── cmdline-A.txt           # boot-A cmdline (PARTLABEL=root-A)
│   ├── cmdline-B.txt           # boot-B cmdline (PARTLABEL=root-B)
│   ├── fstab.template          # /etc/fstab written into both root slots
│   ├── logrotate-agora.conf    # 1 GB cap on /var/log (D56)
│   ├── eeprom-floor.txt        # pinned EEPROM firmware commit
│   └── eeprom-config.template  # NET_INSTALL=0, BOOT_ORDER=0xf461, BOOT_UART=1
├── pi-gen-overlay/             # bolt-on stage for stock pi-gen (D55)
│   └── stage-agora/            # overlay stage
└── .github/workflows/build.yml # CI: pi-gen pinned by SHA, sign + release (D53)
```

## Build approach (D55)

Bolt-on, not a hard fork. Stock pi-gen (pinned by SHA in
`.github/workflows/build.yml`) produces a Bookworm arm64 rootfs tarball and
boot tarball. `image-build/assemble.sh` then:

1. Creates a sparse `.img` and a 5-partition GPT (`partition.sh`).
2. Mounts every partition over loop.
3. Untars the rootfs into **both** `root-A` and `root-B` so the slots are
   structurally identical.
4. Untars the boot tarball into **both** `boot-A` and `boot-B`, then writes
   per-slot `cmdline.txt` (`/boot/firmware/cmdline.txt` on Bookworm — F15)
   and the shared `autoboot.txt` (F6).
5. Writes `/etc/fstab` into both root slots (RW per D57; bind-mounts
   `/var/log` → `/data/var-log` per D56).
6. Strips per-device identity (`/etc/machine-id`, `/etc/ssh/ssh_host_*`) from
   both root slots — firstboot regenerates them (F11).
7. Bakes both signing pubkeys: `/etc/agora/update-pubkey.pem` (primary) and
   `/etc/agora/update-pubkey-recovery.pem` (recovery) per D54.
8. Seeds `/data/SCHEMA_VERSION=1` and creates `/data/var-log/`.
9. xz-compresses the result into `.img.xz` (F19 superseded — image uses xz
   for Pi Imager / balenaEtcher progress-bar accuracy; OTA bundles in
   Phase 2 stay on zstd for fast on-Pi decompression, D17 unchanged).

## Building

Tagged releases are built automatically by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)) — push a
`v*` tag and a signed `.img.xz` + `.minisig` is attached to a draft release.

For local builds, signing-key custody, branch protection, stockroom-Pi
smoke-tests, and the floor-pinning procedure, see
[`image-build/README.md`](image-build/README.md).

## Compatibility

The rootfs and the `agora-app` it runs version-track each other:

- `/etc/agora/version` declares `agora_app_floor` — the oldest `agora-app`
  this rootfs supports (F17, Decision #2).
- `agora-app` release metadata declares `requires_rootfs >=` — the oldest
  rootfs that release will run on.

The CMS checks both before pushing either an OS update or an app update.

# EEPROM-level recovery from a bricked SD

The Pi 5 EEPROM ships with `BOOT_ORDER=0xf461` (F10):

| nibble (LSB→MSB) | source         | meaning                                      |
|------------------|----------------|----------------------------------------------|
| 1                | SD             | try the microSD card first                   |
| 6                | USB MSD        | fall back to USB mass storage                |
| 4                | NVMe           | fall back to NVMe                            |
| f                | restart        | loop                                         |

The last digit being `1` (SD) is intentional but the `6` in the second
position is the recovery escape hatch: if the SD card in the field gets
corrupted, **a tech can recover the device without opening the case** by
plugging in a USB stick that has a working `agora-os` image flashed onto it.

## Recovery procedure

1. On a known-good workstation, flash a working `agora-os-vX.Y.Z.img.zst`
   onto a USB stick using `rpi-imager` or `dd`.
2. Power the field Pi 5 off.
3. Plug the USB stick into one of the Pi 5's USB-3 ports.
4. Power the Pi 5 on.
5. The bootloader fails to read the corrupt SD, falls through to the USB
   stick, and boots into a clean rootfs.
6. From the USB-booted system, reflash the SD card in place (e.g.
   `zstd -d <recovery.img.zst> -c | dd of=/dev/mmcblk0 bs=4M conv=fsync`).
7. Power off, remove the USB stick, power on. Device boots from a fresh
   SD with no on-site SD swap required.

## Why not `BOOT_ORDER=0xf41` (SD only)?

Stricter, but it makes the device unrecoverable from a software-bricked SD
without physically swapping the card. Every site visit costs ~$200 in tech
time; the operational cost of one preventable SD-bricking incident exceeds
the theoretical risk of someone with physical access bypassing controls by
plugging in a USB stick (they could already pull the SD card just as easily).

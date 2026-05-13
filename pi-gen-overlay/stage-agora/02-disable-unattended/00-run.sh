#!/bin/bash -e
# pi-gen substep: Disable unattended-upgrades and apt-daily timers.
#
# agora-os manages OS updates exclusively via the A/B OTA path (Phase 2+).
# An apt-driven background upgrade would mutate an active slot's rootfs
# between OTAs, causing two problems:
#
#   1. Drift between root-A and root-B (one slot apt-upgraded, the other
#      still pristine), which makes "what version is this device on?"
#      ambiguous.
#   2. Mutated files invalidate the OTA bundle's sha256 manifest check —
#      apply-time verification compares slot B against meta.json after
#      unpack, but the running rootfs that bundle.tar derives from drifts
#      under our feet.
#
# Both timers (`apt-daily.timer`, `apt-daily-upgrade.timer`) are stock
# systemd timers that schedule `apt-get update` and `unattended-upgrade`
# runs. Masking — not just disabling — stops a future apt package from
# silently re-enabling them on upgrade.
#
# We also purge the unattended-upgrades package itself. Pi OS Bookworm
# Lite (the stage2 base for agora-os) doesn't always install it, so the
# purge is wrapped in `|| true` to stay tolerant of "not installed."

on_chroot <<'CHEOF'

# ── Stop + disable + mask the apt-daily timers ──
# Mask = create a /dev/null symlink in /etc/systemd/system that wins over
# /lib/systemd, so even `systemctl enable` from a postinst can't bring it
# back without explicit unmask.
systemctl disable --now apt-daily.timer 2>/dev/null || true
systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.timer 2>/dev/null || true
systemctl mask apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service 2>/dev/null || true
systemctl mask apt-daily-upgrade.service 2>/dev/null || true

# ── Purge unattended-upgrades package (if installed) ──
DEBIAN_FRONTEND=noninteractive apt-get purge -y unattended-upgrades 2>/dev/null || true

# ── Belt-and-suspenders: drop a 99-disable conf in case the package
# returns via a future apt install. ──
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-agora-no-unattended <<'APTEOF'
// agora-os manages OS updates via A/B OTA — never run unattended apt.
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
APTEOF

CHEOF

echo "Agora: unattended-upgrades disabled + apt-daily timers masked."

#!/bin/bash
# Flashes the Sonix system (kernel + rootfs) with fastboot, from what
# ./pack_firmware.sh left in output/<model>/:
#
#   ./flash_system.sh                 r1
#   ./flash_system.sh r3proii
#   ./flash_system.sh --erase-ota     also erase the ota partition, so the
#                                     next boot is the system even if the boot
#                                     record says recovery (this also clears a
#                                     fastboot request and the boot logo choice)
#   ./flash_system.sh --no-reboot     stay in fastboot afterwards
#
#   output/<model>/kernel-system.xImage   -> kernel
#   output/<model>/rootfs-system.squashfs -> rootfs
#
# The two come out of the same .upt, so the modules in the root fs are that
# kernel's: flash them together. The player has to be in the fastboot of Zee's
# bootloader (hold Play/Pause at power-on, or "Reboot to fastboot" in the
# recovery's Advanced menu). Zee's fastboot checks each image before writing
# it (uImage header for the kernel).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "error: $*" >&2; exit 1; }

MODEL=r1
ERASE_OTA=0
REBOOT=1
while [ $# -gt 0 ]; do
	case "$1" in
	--erase-ota) ERASE_OTA=1 ;;
	--no-reboot) REBOOT=0 ;;
	-h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	r1|r3proii) MODEL=$1 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

KERNEL=$HERE/output/$MODEL/kernel-system.xImage
ROOTFS=$HERE/output/$MODEL/rootfs-system.squashfs
command -v fastboot >/dev/null || die "fastboot is needed (android-tools / platform-tools)"
for f in "$KERNEL" "$ROOTFS"; do
	[ -f "$f" ] || die "no ${f#"$HERE"/}: run ./pack_firmware.sh"
done
[ -n "$(fastboot devices)" ] ||
	die "no player in fastboot: hold Play/Pause at power-on (Zee's bootloader), then run this again"

echo "=== flashing the $MODEL system"
fastboot flash kernel "$KERNEL"
fastboot flash rootfs "$ROOTFS"
if [ $ERASE_OTA = 1 ]; then
	fastboot erase ota
fi
if [ $REBOOT = 1 ]; then
	fastboot reboot
	[ $ERASE_OTA = 1 ] || echo "note: if the boot record says recovery (ota:kernel2) the player starts the recovery; --erase-ota avoids that"
fi
echo "done"

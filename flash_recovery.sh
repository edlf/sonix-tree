#!/bin/bash
# Flashes Zee's Recovery (kernel2 + rootfs2) with fastboot, from what
# ./build_recovery.sh (or ./pack_recovery.sh) left in output/<model>/:
#
#   ./flash_recovery.sh               r1, then starts the recovery once
#   ./flash_recovery.sh r3proii
#   ./flash_recovery.sh --no-reboot   stay in fastboot afterwards
#
#   output/<model>/kernel2-recovery.xImage   -> kernel2
#   output/<model>/rootfs2-recovery.squashfs -> rootfs2
#
# The root fs carries that kernel's modules: the two are flashed together.
# A recovery packed for HiBy's kernel (build_recovery.sh --stock-kernel) has
# no kernel2-recovery.xImage; then only rootfs2 is flashed and the stock
# kernel2 stays. The player has to be in the fastboot of Zee's bootloader
# (hold Play/Pause at power-on, or "Reboot to fastboot" in the recovery).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "error: $*" >&2; exit 1; }

MODEL=r1
REBOOT=1
while [ $# -gt 0 ]; do
	case "$1" in
	--no-reboot) REBOOT=0 ;;
	-h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	r1|r3proii) MODEL=$1 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

KERNEL=$HERE/output/$MODEL/kernel2-recovery.xImage
ROOTFS=$HERE/output/$MODEL/rootfs2-recovery.squashfs
command -v fastboot >/dev/null || die "fastboot is needed (android-tools / platform-tools)"
[ -f "$ROOTFS" ] || die "no ${ROOTFS#"$HERE"/}: run ./build_recovery.sh $MODEL"
[ -n "$(fastboot devices)" ] ||
	die "no player in fastboot: hold Play/Pause at power-on (Zee's bootloader), then run this again"

echo "=== flashing the $MODEL recovery"
if [ -f "$KERNEL" ]; then
	fastboot flash kernel2 "$KERNEL"
else
	echo "no ${KERNEL#"$HERE"/} (a --stock-kernel recovery): only rootfs2, HiBy's kernel2 stays"
fi
fastboot flash rootfs2 "$ROOTFS"
if [ $REBOOT = 1 ]; then
	fastboot reboot recovery
fi
echo "done"

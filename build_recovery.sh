#!/bin/bash
# Builds Zee's Recovery (kernel2 + rootfs2) for a player, from scratch or
# from what is already in output/:
#
#   ./build_recovery.sh                  r1, with the Sonix kernel
#   ./build_recovery.sh r1 r3proii       those players
#   ./build_recovery.sh --stock-kernel   keep HiBy's kernel2: only rootfs2 is made
#   ./build_recovery.sh --no-build       build nothing that output/ already has:
#                                        only the recovery app and the image
#   ./build_recovery.sh --dump DIR       the NAND dump the stock recovery root fs
#                                        comes from (default ~/<model>-mtd), when
#                                        extracted_assets/<model>/recovery-rootfs
#                                        is not there yet
#   ./build_recovery.sh --jobs N         parallel jobs (default: CPUs)
#
# output/<model>/
#   kernel2-recovery.xImage        the Sonix kernel (not with --stock-kernel)
#   rootfs2-recovery.squashfs      the recovery root fs: Zee's Recovery, and
#                                  the kernel's own modules
#
# The steps, per player:
#   1. the stock recovery root fs: ./extract_firmware.sh --recovery DUMP MODEL
#      (once; the .upt firmware does not contain it)
#   2. kernel and U-Boot: ./build_images.sh MODEL (incremental). The U-Boot
#      image is bundled for the recovery's "Install fastboot" (R1).
#   3. the recovery app: make -C recovery MODEL=MODEL (its toolchain, LVGL
#      and FreeType are its own, in recovery/deps/)
#   4. the image: ./pack_recovery.sh [--kernel] MODEL. With the Sonix kernel
#      it puts module_driver/ together from the stock recovery's, the
#      kernel's output/<model>/modules/ and recovery/overlay/<model>/.
#
# Nothing here needs sonix-player.
#
# With --no-build, step 2 only checks that output/ has what it would make,
# and fails when it does not.
#
# Flashing (Zee's bootloader in fastboot: hold Play/Pause at power-on). Both
# partitions together: the modules in rootfs2 are the kernel's.
#   fastboot flash kernel2 output/r1/kernel2-recovery.xImage
#   fastboot flash rootfs2 output/r1/rootfs2-recovery.squashfs
#   fastboot reboot recovery
#
# Nothing in this script touches a device.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "##### [$1] $2"; }

JOBS=$(nproc)
STOCK_KERNEL=0
NO_BUILD=0
DUMP=
MODELS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--stock-kernel) STOCK_KERNEL=1 ;;
	--no-build) NO_BUILD=1 ;;
	--dump) [ $# -ge 2 ] || die "--dump needs a folder"; DUMP=$2; shift ;;
	--jobs) [ $# -ge 2 ] || die "--jobs needs a number"; JOBS=$2; shift ;;
	-h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	r1|r3proii) MODELS+=("$1") ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done
[ ${#MODELS[@]} -gt 0 ] || MODELS=(r1)

for MODEL in "${MODELS[@]}"; do
	OUT=$HERE/output/$MODEL

	step "$MODEL" "1/4 stock recovery root fs"
	if [ -x "$HERE/extracted_assets/$MODEL/recovery-rootfs/usr/bin/recoveryd" ]; then
		echo "extracted_assets/$MODEL/recovery-rootfs is there"
	else
		d=${DUMP:-$HOME/$MODEL-mtd}
		[ -e "$d" ] || die "no stock recovery yet and no NAND dump at $d: dump the player's flash (see recovery/README.md) and pass --dump DIR"
		"$HERE/extract_firmware.sh" --recovery "$d" "$MODEL"
	fi

	step "$MODEL" "2/4 kernel and U-Boot"
	if [ $NO_BUILD = 1 ]; then
		if [ $STOCK_KERNEL = 0 ]; then
			for f in xImage modules.builtin modules; do
				[ -e "$OUT/$f" ] || die "--no-build: no output/$MODEL/$f"
			done
		fi
		[ -f "$OUT/u-boot-hiby_$MODEL.bin" ] || echo "no output/$MODEL/u-boot-hiby_$MODEL.bin: \"Install fastboot\" will not be offered"
		echo "using what output/$MODEL has"
	elif [ $STOCK_KERNEL = 1 ]; then
		"$HERE/build_images.sh" --jobs "$JOBS" --uboot-only "$MODEL"
	else
		"$HERE/build_images.sh" --jobs "$JOBS" "$MODEL"
	fi

	step "$MODEL" "3/4 recovery app"
	make -C "$HERE/recovery" -j"$JOBS" MODEL="$MODEL"

	step "$MODEL" "4/4 recovery image"
	if [ $STOCK_KERNEL = 1 ]; then
		"$HERE/pack_recovery.sh" "$MODEL"
	else
		"$HERE/pack_recovery.sh" --kernel "$MODEL"
	fi
done

echo
echo "##### done. Flash with Zee's bootloader in fastboot (hold Play/Pause at power-on):"
for MODEL in "${MODELS[@]}"; do
	if [ $STOCK_KERNEL = 0 ]; then
		echo "  fastboot flash kernel2 output/$MODEL/kernel2-recovery.xImage"
	fi
	echo "  fastboot flash rootfs2 output/$MODEL/rootfs2-recovery.squashfs"
done
echo "  fastboot reboot recovery"
echo "(or ./flash_recovery.sh [model], which does the same)"
[ $STOCK_KERNEL = 1 ] || echo "Flash kernel2 and rootfs2 together: the modules in rootfs2 are that kernel's."

#!/bin/bash
# Builds the Sonix Player firmware images (.upt) from scratch, for every
# player with a stock firmware in original_firmware/:
#
#   ./build_firmware.sh                      everything below, in order
#   ./build_firmware.sh --skip-kernel        reuse the kernels in output/<model>/
#   ./build_firmware.sh --strip-debug-tools  passed on to pack_firmware.sh
#   ./build_firmware.sh --jobs 8             parallel jobs (default: CPUs)
#
# 1. extract_firmware.sh       the stock root fs of each .upt, into
#                              extracted_assets/<model>/rootfs/
# 2. build_images.sh --kernel-only <models>
#                              the kernel and its modules, into output/<model>/
# 3. make target               sonix_player and sonix_launch, in
#                              sonix-player/sonix-player (the first run also
#                              builds its MIPS toolchain and libraries)
# 4. pack_firmware.sh          output/<model>/<model>.upt, plus
#                              kernel-system.xImage and rootfs-system.squashfs
#
# Each step stops the script if it fails. The players are the ones that have
# an original_firmware/<model>(...).upt; the others are left out.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ALL_MODELS=(r1 r3proii)

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "##### $*"; }

JOBS=$(nproc)
SKIP_KERNEL=0
PACK_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--skip-kernel) SKIP_KERNEL=1 ;;
	--strip-debug-tools) PACK_ARGS+=("$1") ;;
	--jobs) [ $# -ge 2 ] || die "--jobs needs a number"; JOBS=$2; shift ;;
	-h|--help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

# the players with a stock firmware to start from
MODELS=()
for model in "${ALL_MODELS[@]}"; do
	shopt -s nullglob
	stock=("$HERE/original_firmware/$model("*").upt" "$HERE/original_firmware/$model.upt")
	shopt -u nullglob
	if [ ${#stock[@]} -gt 0 ]; then
		MODELS+=("$model")
	else
		echo "[$model] no original_firmware/$model(...).upt: left out"
	fi
done
[ ${#MODELS[@]} -gt 0 ] || die "no stock firmware in original_firmware/"
echo "players: ${MODELS[*]}"

step "1/4 extracting the stock firmware"
"$HERE/extract_firmware.sh"

step "2/4 building the kernel"
if [ "$SKIP_KERNEL" = 1 ]; then
	for model in "${MODELS[@]}"; do
		[ -f "$HERE/output/$model/xImage" ] ||
			die "[$model] --skip-kernel, but there is no output/$model/xImage"
	done
	echo "skipped (--skip-kernel): using the kernels in output/"
else
	"$HERE/build_images.sh" --kernel-only --jobs "$JOBS" "${MODELS[@]}"
fi

step "3/4 building sonix-player"
[ -f "$HERE/sonix-player/sonix-player/Makefile" ] ||
	die "no sonix-player/sonix-player/Makefile (git submodule update --init?)"
make -C "$HERE/sonix-player/sonix-player" -j"$JOBS" target

step "4/4 packing the firmware"
"$HERE/pack_firmware.sh" ${PACK_ARGS[@]+"${PACK_ARGS[@]}"}

echo
for model in "${MODELS[@]}"; do
	echo "done: output/$model/$model.upt"
done

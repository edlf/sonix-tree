#!/bin/bash
# Builds the kernel and the U-Boot images of the HiBy players into output/:
#
#   ./build_images.sh                    both players: r1 and r3proii
#   ./build_images.sh r1                 only the ones named
#   ./build_images.sh --kernel-only r1   (or --uboot-only)
#   ./build_images.sh --jobs 8 ...       parallel jobs (default: CPUs)
#
# output/<model>/
#   xImage                     the kernel (a uImage, for the kernel partition)
#   System.map, config         its symbol table and configuration
#   modules/                   the kernel's modules (.ko): only the ones this
#                              configuration builds (modules.order)
#   modules.builtin            names of the drivers built into the kernel
#   u-boot-hiby_<model>.bin              SPL + U-Boot, blank partition table
#   u-boot-hiby_<model>-nouid.bin        the same, USB serial not read from NAND
#   u-boot-hiby_<model>-withparts.bin    with the partition table, and
#   u-boot-hiby_<model>-nouid-withparts.bin
#                              the same for -nouid; only for a player with a
#                              partitions/<model>.txt (see below)
#   build-<what>.log           the build logs
#
# The kernel is built from kernel/ with its own defconfig
# (hiby_<model>_defconfig), out of tree in build/kernel-<model>, so the source
# stays clean and both players can be built side by side.
#
# U-Boot is built from a copy of uboot/ in build/uboot-<model>[-nouid], so the
# submodule is never touched. The -nouid build comments out
# CONFIG_FASTBOOT_SERIAL_NAND_UID in that copy (see uboot/README.md).
#
# The -withparts images get the partition table at 0x5800-0x5bff, generated
# by partitions/mkparttable.py from partitions/<model>.txt. A player without
# such a file gets no -withparts images.
#
# Toolchains (the bin/ folder, override with the variables):
#   KERNEL_TOOLCHAIN  the Ingenic SDK's prebuilts/toolchains/mips-gcc720-glibc229
#   UBOOT_TOOLCHAIN   mips-gcc720-glibc229_br_linux_r5.0.2-gcc720-fp32, as in
#                     uboot/README.md
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KSRC=$HERE/kernel
USRC=$HERE/uboot
BUILD=$HERE/build
OUTPUT=$HERE/output
KERNEL_TOOLCHAIN=${KERNEL_TOOLCHAIN:-$HOME/ingenic-linux-kernel4.4.94-x1600-v6.0-20240606/prebuilts/toolchains/mips-gcc720-glibc229/bin}
UBOOT_TOOLCHAIN=${UBOOT_TOOLCHAIN:-$HOME/mips-gcc720-glibc229_br_linux_r5.0.2-gcc720-fp32/bin}
ALL_MODELS=(r1 r3proii)

JOBS=$(nproc)
DO_KERNEL=1
DO_UBOOT=1
MODELS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--jobs) JOBS=$2; shift ;;
	--kernel-only) DO_UBOOT=0 ;;
	--uboot-only) DO_KERNEL=0 ;;
	-h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	r1|r3proii) MODELS+=("$1") ;;
	*) echo "unknown argument: $1 (models: ${ALL_MODELS[*]})" >&2; exit 2 ;;
	esac
	shift
done
[ ${#MODELS[@]} -gt 0 ] || MODELS=("${ALL_MODELS[@]}")

die() { echo "error: $*" >&2; exit 1; }
# runs a command with its output in a log; on failure shows the end of it
logged() {
	local log=$1; shift
	if ! "$@" >>"$log" 2>&1; then
		echo "  failed, the end of $log:" >&2
		tail -25 "$log" >&2
		return 1
	fi
}

# --- checks -------------------------------------------------------------------
if [ "$DO_KERNEL" = 1 ]; then
	[ -x "$KERNEL_TOOLCHAIN/mips-linux-gnu-gcc" ] || die "no mips-linux-gnu-gcc in KERNEL_TOOLCHAIN=$KERNEL_TOOLCHAIN"
	[ -f "$KSRC/Makefile" ] || die "no kernel in $KSRC (git submodule update --init?)"
	[ "$(cat "$KSRC/.scmversion" 2>/dev/null)" = "+" ] ||
		die "$KSRC/.scmversion must hold '+' (the vermagic 4.4.94+ the HiBy modules need)"
	[ ! -f "$KSRC/.config" ] || die "$KSRC has a .config: the build is out of tree, run 'make mrproper' there first"
fi
if [ "$DO_UBOOT" = 1 ]; then
	[ -x "$UBOOT_TOOLCHAIN/mips-linux-gnu-gcc" ] || die "no mips-linux-gnu-gcc in UBOOT_TOOLCHAIN=$UBOOT_TOOLCHAIN"
	[ -f "$USRC/boards.cfg" ] || die "no U-Boot in $USRC (git submodule update --init?)"
	command -v rsync >/dev/null || die "rsync is needed"
fi

# --- kernel -------------------------------------------------------------------
build_kernel() {
	local model=$1 out=$OUTPUT/$1 obj=$BUILD/kernel-$1
	local log=$out/build-kernel.log
	local mk=(make -C "$KSRC" O="$obj" ARCH=mips CROSS_COMPILE=mips-linux-gnu- "HOSTCC=gcc -fcommon")
	echo "[$model] kernel"
	[ -f "$KSRC/arch/mips/configs/hiby_${model}_defconfig" ] || die "no hiby_${model}_defconfig in the kernel"
	mkdir -p "$obj" "$out"
	: >"$log"
	(
		export PATH=$KERNEL_TOOLCHAIN:$PATH
		logged "$log" "${mk[@]}" "hiby_${model}_defconfig"
		logged "$log" "${mk[@]}" -j"$JOBS" xImage modules
	)
	cp "$obj/arch/mips/boot/compressed/xImage" "$out/xImage"
	cp "$obj/System.map" "$out/System.map"
	cp "$obj/.config" "$out/config"

	# The modules of this configuration are the ones in modules.order. A .ko
	# left in the build folder by an earlier configuration (a module since
	# built in, or turned off) is not one of them: it is deleted, so that
	# nothing picks it up by mistake.
	local order=$obj/modules.order want
	[ -f "$order" ] || die "[$model] no modules.order in $obj"
	want=$(sed 's|^kernel/||' "$order")
	local ko rel
	while IFS= read -r ko; do
		rel=${ko#"$obj"/}
		grep -qxF "$rel" <<<"$want" || { echo "  stale, deleted: $rel"; rm -f "$ko"; }
	done < <(find "$obj" -name '*.ko')

	# output/<model>/modules/ gets exactly those; say which ones went away
	local before=
	[ -d "$out/modules" ] && before=$(ls "$out/modules")
	rm -rf "$out/modules" && mkdir -p "$out/modules"
	for rel in $want; do cp "$obj/$rel" "$out/modules/"; done
	local gone
	gone=$(comm -23 <(echo "$before" | grep . | sort) <(ls "$out/modules" | sort) | tr '\n' ' ')
	[ -z "$gone" ] || echo "  no longer modules (removed from output/$model/modules): $gone"

	# what is built in, by module name, for whoever installs the modules: a
	# stock .ko of the same name must not be loaded on top of it
	sed 's|.*/||; s|\.ko$||' "$obj/modules.builtin" | sort >"$out/modules.builtin"

	local vermagic=
	if ls "$out"/modules/*.ko >/dev/null 2>&1; then
		vermagic=$(strings -a "$out"/modules/*.ko | sed -n 's/^vermagic=//p' | sort -u)
		[ "$(echo "$vermagic" | wc -l)" = 1 ] && [[ "$vermagic" == "4.4.94+ "* ]] ||
			die "[$model] unexpected module vermagic: $vermagic"
	fi
	echo "  xImage $(stat -c %s "$out/xImage") bytes, $(ls "$out/modules" | wc -l) modules${vermagic:+, vermagic $vermagic}"
}

# --- U-Boot -------------------------------------------------------------------
# build_uboot MODEL [nouid]
build_uboot() {
	local model=$1 variant=${2:-} out=$OUTPUT/$1
	local suffix=${variant:+-$variant}
	local work=$BUILD/uboot-$model$suffix
	local log=$out/build-uboot$suffix.log
	local target=hiby_${model}_xImage_sfc_nand
	local image=$out/u-boot-hiby_$model$suffix.bin
	echo "[$model] U-Boot${variant:+ ($variant)}"
	grep -q "^$target " "$USRC/boards.cfg" || die "no $target in uboot/boards.cfg"
	mkdir -p "$out"
	: >"$log"
	rsync -a --delete --exclude=.git "$USRC/" "$work/"
	if [ "$variant" = nouid ]; then
		local h=$work/include/configs/hiby_x1600_common.h
		grep -q '^#define CONFIG_FASTBOOT_SERIAL_NAND_UID' "$h" || die "no CONFIG_FASTBOOT_SERIAL_NAND_UID in $h"
		sed -i 's|^#define CONFIG_FASTBOOT_SERIAL_NAND_UID.*|/* & (off: -nouid build) */|' "$h"
	fi
	(
		export PATH=$UBOOT_TOOLCHAIN:$PATH CROSS_COMPILE=mips-linux-gnu-
		cd "$work"
		logged "$log" make distclean
		# the SDK Makefile sometimes trips over its own dependency files with
		# -j ("multiple target patterns"): then once more, serially
		if ! make -j"$JOBS" "$target" >>"$log" 2>&1; then
			echo "  parallel build failed, retrying with one job" | tee -a "$log"
			logged "$log" make distclean
			logged "$log" make "$target"
		fi
	)
	cp "$work/u-boot-with-spl.bin" "$image"
	local size
	size=$(stat -c %s "$image")
	[ "$size" -le $((0x80000)) ] || die "[$model] $image is $size bytes, more than the 512 KiB uboot partition"
	echo "  $(basename "$image"): $size bytes"

	# the -withparts copy, with the table generated from partitions/<model>.txt
	local txt=$HERE/partitions/$model.txt
	if [ ! -f "$txt" ]; then
		echo "  no partitions/$model.txt: no -withparts image"
		return
	fi
	# the image must leave the table area blank for it
	if [ "$size" -gt $((0x5800)) ] &&
		[ -n "$(dd if="$image" bs=1 skip=$((0x5800)) count=1024 2>/dev/null | tr -d '\377')" ]; then
		die "[$model] $image has data at 0x5800-0x5bff, where the partition table goes"
	fi
	local table=$BUILD/parttable-$model.bin
	python3 "$HERE/partitions/mkparttable.py" "$txt" "$table"
	local wp=$out/u-boot-hiby_$model$suffix-withparts.bin
	cp "$image" "$wp"
	# an image that does not reach the table is padded with 0xff first
	if [ "$size" -lt $((0x5c00)) ]; then
		head -c $((0x5c00 - size)) /dev/zero | tr '\0' '\377' >>"$wp"
	fi
	dd if="$table" of="$wp" bs=1 seek=$((0x5800)) conv=notrunc 2>/dev/null
	echo "  $(basename "$wp"): partition table from partitions/$model.txt"
}

for model in "${MODELS[@]}"; do
	if [ "$DO_KERNEL" = 1 ]; then build_kernel "$model"; fi
	if [ "$DO_UBOOT" = 1 ]; then
		build_uboot "$model"
		build_uboot "$model" nouid
	fi
done
echo "done: $OUTPUT"

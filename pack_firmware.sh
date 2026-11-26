#!/bin/bash
# Packs the Sonix Player firmware images (.upt) for both players, with the
# kernels and modules from build_images.sh:
#
#   ./build_images.sh --kernel-only     (first: output/<model>/xImage etc.)
#   ./pack_firmware.sh                  -> output/r1/r1.upt, output/r3proii/r3proii.upt
#                                       and, for fastboot (flash_system.sh),
#                                       output/<model>/kernel-system.xImage and
#                                       rootfs-system.squashfs, taken from that .upt
#   ./pack_firmware.sh --strip-debug-tools
#                                       the same, without the stock debugging
#                                       tools (passed on to the packer)
#
# sonix-player/sonix-packer/sonix_firmware_packer.sh does the packing. It
# takes everything from its own folder, so it runs from a copy of that folder
# in build/pack/, never touching the sonix-player checkout:
#
#   <model>_original.upt   the stock firmware, original_firmware/<model>(*).upt
#   sonix_player,          from sonix-player/sonix-player (make target)
#   sonix_launch
#   kernel/xImage-<DIR>    output/<model>/xImage
#   kernel/modules.builtin-<DIR>
#                          output/<model>/modules.builtin: what the packer
#                          drops from module_driver/
#   assets/<DIR>/module_driver/*.ko
#                          each one that output/<model>/modules/ also has is
#                          replaced by that build, so the modules match the
#                          kernel they go in with
#
# Needs what the packer needs: 7z, unsquashfs/mksquashfs and an ISO tool
# (mkisofs, genisoimage or xorrisofs).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKER_SRC=$HERE/sonix-player/sonix-packer
PLAYER_DIR=$HERE/sonix-player/sonix-player
STAGE=$HERE/build/pack
OUTPUT=$HERE/output
# model in output/ and original_firmware/ | folder name in the packer
MODELS=("r1|R1" "r3proii|R3PII")

die() { echo "error: $*" >&2; exit 1; }

PACKER_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--strip-debug-tools) PACKER_ARGS+=("$1") ;;
	-h|--help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

[ -f "$PACKER_SRC/sonix_firmware_packer.sh" ] || die "no packer in $PACKER_SRC"
for f in sonix_player sonix_launch; do
	[ -f "$PLAYER_DIR/$f" ] || die "no $PLAYER_DIR/$f: run 'make target' in sonix-player/sonix-player"
done
command -v rsync >/dev/null || die "rsync is needed"

echo "=== staging the packer in build/pack"
mkdir -p "$STAGE"
# the packer's own folder, minus anything a previous run left behind
rsync -a --delete --exclude=temp/ --exclude=squashfs-root/ --exclude='*.upt' \
	--exclude=rootfs_original.squashfs "$PACKER_SRC/" "$STAGE/"
cp "$PLAYER_DIR/sonix_player" "$PLAYER_DIR/sonix_launch" "$STAGE/"
# stock firmware and results of an earlier run
find "$STAGE" -maxdepth 1 -name '*.upt' -delete

packed=()
for entry in "${MODELS[@]}"; do
	IFS='|' read -r model dir <<<"$entry"
	out=$OUTPUT/$model
	shopt -s nullglob
	stock=("$HERE/original_firmware/$model("*").upt" "$HERE/original_firmware/$model.upt")
	shopt -u nullglob
	if [ ${#stock[@]} -eq 0 ]; then
		echo "[$model] no original_firmware/$model(...).upt: skipped"
		continue
	fi
	[ -f "$out/xImage" ] && [ -f "$out/modules.builtin" ] && [ -d "$out/modules" ] ||
		die "[$model] no kernel in output/$model: run ./build_images.sh --kernel-only $model"
	echo "[$model] stock firmware: $(basename "${stock[0]}")"
	cp "${stock[0]}" "$STAGE/${model}_original.upt"
	cp "$out/xImage" "$STAGE/kernel/xImage-$dir"
	cp "$out/modules.builtin" "$STAGE/kernel/modules.builtin-$dir"
	# modules built with this kernel replace the asset copies of the same name
	md=$STAGE/assets/$dir/module_driver
	n=0
	for ko in "$md"/*.ko; do
		[ -e "$ko" ] || continue
		new=$out/modules/$(basename "$ko")
		if [ -f "$new" ]; then
			cp "$new" "$ko"
			n=$((n + 1))
		fi
	done
	echo "[$model] kernel output/$model/xImage, $n asset modules replaced by this build"
	packed+=("$model")
done
[ ${#packed[@]} -gt 0 ] || die "nothing to pack: no stock firmware in original_firmware/"

echo "=== packing"
( cd "$STAGE" && ./sonix_firmware_packer.sh ${PACKER_ARGS[@]+"${PACKER_ARGS[@]}"} )

# The system's kernel and root fs as plain images, for flash_system.sh: taken
# back out of the package just written, so they are exactly what it installs
# and go together (the modules in the root fs are that kernel's). Its chunks
# are joined in order and checked against the md5 ota_update.in gives.
extract_image() { # extract_image DIR IMG_NAME OUT
	local dir=$1 name=$2 out=$3 want have
	want=$(awk -F= -v n="$name" '/^img_name=/{i=$2} i==n && /^img_md5=/{print $2; exit}' "$dir/ota_update.in" | tr -d '\r ')
	cat "$dir/$name".[0-9][0-9][0-9][0-9].* >"$out.part"
	have=$(md5sum "$out.part" | cut -d' ' -f1)
	[ -n "$want" ] && [ "$want" = "$have" ] || { rm -f "$out.part"; die "$name in the package does not match its md5"; }
	mv "$out.part" "$out"
}

for model in "${packed[@]}"; do
	[ -s "$STAGE/$model.upt" ] || die "the packer wrote no $model.upt"
	mv "$STAGE/$model.upt" "$OUTPUT/$model/$model.upt"
	echo "-> output/$model/$model.upt ($(stat -c %s "$OUTPUT/$model/$model.upt") bytes)"
	x=$STAGE/extract-$model
	rm -rf "$x"
	7z x -y -o"$x" "$OUTPUT/$model/$model.upt" >/dev/null || die "cannot open output/$model/$model.upt"
	d=$(ls -d "$x"/ota_v* | head -1)
	extract_image "$d" xImage "$OUTPUT/$model/kernel-system.xImage"
	extract_image "$d" rootfs.squashfs "$OUTPUT/$model/rootfs-system.squashfs"
	rm -rf "$x"
	echo "-> output/$model/kernel-system.xImage, output/$model/rootfs-system.squashfs (for flash_system.sh)"
done

#!/bin/bash
# Takes the kernel and root fs out of stock HiBy firmware images (.upt),
# intact, and unpacks the root fs, one folder per player:
#
#   extracted_assets/<model>/kernel.xImage     the kernel partition image
#   extracted_assets/<model>/rootfs.squashfs   the rootfs partition image
#   extracted_assets/<model>/rootfs/           that root fs, unpacked
#
#   ./extract_firmware.sh                 every .upt in original_firmware/
#   ./extract_firmware.sh FILE.upt ...    only those
#   ./extract_firmware.sh --recovery DUMP MODEL
#                                         the recovery from a NAND dump:
#                                         extracted_assets/<MODEL>/rootfs2.bin
#                                         and kernel2.bin (the partitions as
#                                         dumped), and recovery-rootfs/
#
# A .upt is an ISO image. Its ota_v0/ folder holds each image (xImage,
# rootfs.squashfs) as 512 KiB chunks, <img>.NNNN.<md5>, and ota_update.in
# gives the size and md5 of the whole image. The chunks are joined in order
# and checked against both; the copy is kept as is, and the root fs is
# unpacked from it with unsquashfs.
#
# The model comes from ota_v0/ota_compatibility.in (hiby_<model>_x1600_...),
# or from the file name (r1(v2.0).upt -> r1) if that is missing.
#
# The recovery (kernel2/rootfs2) is not in a .upt, so it comes from a dump
# of the player's flash instead. DUMP is either the rootfs2 partition image
# itself or a folder holding the partitions: one mtd<N> file each (as
# "cat /dev/mtdN > mtdN" on the device gives: rootfs2 is mtd4, kernel2 mtd3,
# in the layout of partitions/<MODEL>.txt), or recovery.rootfs and
# kernel2.bin. The root fs has to be a squashfs with /usr/bin/recoveryd (the
# stock recovery), so the main rootfs (mtd2) is refused. Both partitions are
# kept as dumped (kernel2 only when DUMP is a folder that has it).
#
# Needs 7z (p7zip-full) and unsquashfs (squashfs-tools). Run as a normal user,
# device nodes in /dev are not created (unsquashfs says so); the rest of the
# rootfs is complete.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$HERE/extracted_assets

TOOLS="7z unsquashfs md5sum"
[ "${1:-}" = --recovery ] && TOOLS=unsquashfs
for tool in $TOOLS; do
	command -v "$tool" >/dev/null || {
		echo "missing $tool (Debian/Ubuntu: sudo apt install p7zip-full squashfs-tools)" >&2
		exit 1
	}
done

if [ $# -eq 0 ]; then
	shopt -s nullglob
	set -- "$HERE"/original_firmware/*.upt
	shopt -u nullglob
	[ $# -gt 0 ] || { echo "no .upt files in $HERE/original_firmware" >&2; exit 1; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# unpack_squashfs SQUASHFS DEST [MUST_HAVE]: unpack into a fresh folder,
# then move it into place; with MUST_HAVE, only if that path is in it
unpack_squashfs() {
	local sq=$1 dest=$2 must=${3:-} log=$TMP/unsquashfs.log skipped
	mkdir -p "$(dirname "$dest")"
	rm -rf "$dest.new"
	if ! unsquashfs -no-progress -d "$dest.new" "$sq" >"$log" 2>&1; then
		# as a normal user only the device nodes fail; anything else is fatal
		if grep -vE "could not create (character|block) device|because you're not superuser|^$" "$log" | grep -qiE "error|failed|could not"; then
			cat "$log" >&2
			exit 1
		fi
	fi
	if [ -n "$must" ] && [ ! -e "$dest.new/$must" ]; then
		echo "  no /$must in $sq: not the recovery root fs (wrong partition?)" >&2
		rm -rf "$dest.new"
		exit 1
	fi
	skipped=$(grep -cE "could not create (character|block) device" "$log" || true)
	rm -rf "$dest" && mv "$dest.new" "$dest"
	echo "  -> ${dest#"$HERE"/} ($(find "$dest" | wc -l) entries$([ "$skipped" -gt 0 ] && echo ", $skipped device nodes skipped"))"
}

# join_image OTA_DIR NAME OUT: the chunks of NAME joined in order (NNNN has a
# fixed width, so sorting the names sorts them by number), checked against
# the size and md5 ota_update.in gives, and written to OUT
join_image() {
	local ota=$1 name=$2 out=$3 want_size want_md5 size md5 chunks
	want_size=$(awk -F= -v n="$name" '/^img_name=/{i=$2} i==n && /^img_size=/{print $2; exit}' "$ota/ota_update.in" | tr -d '\r ')
	want_md5=$(awk -F= -v n="$name" '/^img_name=/{i=$2} i==n && /^img_md5=/{print $2; exit}' "$ota/ota_update.in" | tr -d '\r ')
	[ -n "$want_size" ] && [ -n "$want_md5" ] || { echo "  no $name entry in ota_update.in" >&2; exit 1; }
	chunks=$(ls "$ota/$name".[0-9][0-9][0-9][0-9].* | sort)
	# shellcheck disable=SC2086
	cat $chunks >"$out.part"
	size=$(stat -c %s "$out.part")
	md5=$(md5sum "$out.part" | cut -d' ' -f1)
	if [ "$size" != "$want_size" ] || [ "$md5" != "$want_md5" ]; then
		echo "  $name is $size bytes, md5 $md5; ota_update.in says $want_size, $want_md5" >&2
		rm -f "$out.part"
		exit 1
	fi
	mv "$out.part" "$out"
	echo "  -> ${out#"$HERE"/} ($(echo "$chunks" | wc -l) chunks, $size bytes, md5 ok)"
}

if [ "${1:-}" = --recovery ]; then
	[ $# -eq 3 ] || { echo "usage: $0 --recovery DUMP MODEL" >&2; exit 1; }
	DUMP=$2
	MODEL=$(echo "$3" | tr 'A-Z' 'a-z')
	KDUMP=
	if [ -d "$DUMP" ]; then
		dir=$DUMP
		DUMP=$dir/mtd4
		[ -f "$DUMP" ] || DUMP=$dir/recovery.rootfs
		for k in "$dir/mtd3" "$dir/kernel2.bin"; do
			[ -f "$k" ] && { KDUMP=$k; break; }
		done
	fi
	[ -f "$DUMP" ] || { echo "no such file: $DUMP" >&2; exit 1; }
	echo "=== recovery of $MODEL from $DUMP"
	# a raw partition dump is the squashfs plus the erased rest of the
	# partition; unsquashfs reads only the squashfs part
	case $(head -c 4 "$DUMP") in
	hsqs) ;;
	*) echo "  $DUMP is not a squashfs (wrong partition?)" >&2; exit 1 ;;
	esac
	unpack_squashfs "$DUMP" "$OUT/$MODEL/recovery-rootfs" usr/bin/recoveryd
	# the partitions as dumped, after the root fs proved to be the recovery's
	cp "$DUMP" "$OUT/$MODEL/rootfs2.bin"
	echo "  -> ${OUT#"$HERE"/}/$MODEL/rootfs2.bin ($(stat -c %s "$DUMP") bytes, as dumped)"
	if [ -n "$KDUMP" ]; then
		[ "$(od -An -tx1 -N4 "$KDUMP" | tr -d ' ')" = 27051956 ] ||
			{ echo "  $KDUMP is not a uImage (wrong partition?)" >&2; exit 1; }
		cp "$KDUMP" "$OUT/$MODEL/kernel2.bin"
		echo "  -> ${OUT#"$HERE"/}/$MODEL/kernel2.bin ($(stat -c %s "$KDUMP") bytes, as dumped)"
	fi
	exit 0
fi

for UPT in "$@"; do
	[ -f "$UPT" ] || { echo "no such file: $UPT" >&2; exit 1; }
	echo "=== $(basename "$UPT")"
	W=$TMP/work
	rm -rf "$W" && mkdir -p "$W"
	7z x -y -o"$W" "$UPT" 'ota_v0/rootfs.squashfs.*' 'ota_v0/xImage.*' ota_v0/ota_update.in \
		ota_v0/ota_compatibility.in >/dev/null
	OTA=$W/ota_v0
	[ -f "$OTA/ota_update.in" ] || { echo "  no ota_v0/ota_update.in: not a HiBy OTA image" >&2; exit 1; }

	# the model
	MODEL=
	if [ -f "$OTA/ota_compatibility.in" ]; then
		MODEL=$(sed -n 's/^compatibility=hiby_\([a-z0-9]*\)_.*/\1/p' "$OTA/ota_compatibility.in" | tr -d '\r')
	fi
	if [ -z "$MODEL" ]; then
		MODEL=$(basename "$UPT" .upt)
		MODEL=${MODEL%%(*}
		MODEL=$(echo "$MODEL" | tr 'A-Z' 'a-z')
	fi
	echo "  model: $MODEL"

	# the two images, intact, then the root fs unpacked from its copy
	mkdir -p "$OUT/$MODEL"
	join_image "$OTA" xImage "$OUT/$MODEL/kernel.xImage"
	join_image "$OTA" rootfs.squashfs "$OUT/$MODEL/rootfs.squashfs"
	unpack_squashfs "$OUT/$MODEL/rootfs.squashfs" "$OUT/$MODEL/rootfs"
done

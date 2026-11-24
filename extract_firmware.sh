#!/bin/bash
# Unpacks the root filesystem of stock HiBy firmware images (.upt) into
# extracted_assets/<model>/rootfs/, one folder per player. The kernel is left
# alone.
#
#   ./extract_firmware.sh                 every .upt in original_firmware/
#   ./extract_firmware.sh FILE.upt ...    only those
#   ./extract_firmware.sh --recovery DUMP MODEL
#                                         the recovery root fs from a NAND
#                                         dump, into
#                                         extracted_assets/<MODEL>/recovery-rootfs/
#
# A .upt is an ISO image. Its ota_v0/ folder holds the rootfs as 512 KiB
# chunks, rootfs.squashfs.NNNN.<md5>, and ota_update.in gives the size and md5
# of the whole squashfs. The chunks are joined in order, checked against
# both, and unpacked with unsquashfs.
#
# The model comes from ota_v0/ota_compatibility.in (hiby_<model>_x1600_...),
# or from the file name (r1(v2.0).upt -> r1) if that is missing.
#
# The recovery (kernel2/rootfs2) is not in a .upt, so it comes from a dump
# of the player's flash instead. DUMP is either the rootfs2 partition image
# itself or a folder holding one mtd<N> file per partition (as
# "cat /dev/mtdN > mtdN" on the device gives): there rootfs2 is mtd4, the
# second root fs in the layout of partitions/<MODEL>.txt. It has to be a
# squashfs with /usr/bin/recoveryd (the stock recovery), so the main rootfs
# (mtd2) is refused.
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

if [ "${1:-}" = --recovery ]; then
	[ $# -eq 3 ] || { echo "usage: $0 --recovery DUMP MODEL" >&2; exit 1; }
	DUMP=$2
	MODEL=$(echo "$3" | tr 'A-Z' 'a-z')
	[ -d "$DUMP" ] && DUMP=$DUMP/mtd4
	[ -f "$DUMP" ] || { echo "no such file: $DUMP" >&2; exit 1; }
	echo "=== recovery of $MODEL from $DUMP"
	# a raw partition dump is the squashfs plus the erased rest of the
	# partition; unsquashfs reads only the squashfs part
	case $(head -c 4 "$DUMP") in
	hsqs) ;;
	*) echo "  $DUMP is not a squashfs (wrong partition?)" >&2; exit 1 ;;
	esac
	unpack_squashfs "$DUMP" "$OUT/$MODEL/recovery-rootfs" usr/bin/recoveryd
	exit 0
fi

for UPT in "$@"; do
	[ -f "$UPT" ] || { echo "no such file: $UPT" >&2; exit 1; }
	echo "=== $(basename "$UPT")"
	W=$TMP/work
	rm -rf "$W" && mkdir -p "$W"
	7z x -y -o"$W" "$UPT" 'ota_v0/rootfs.squashfs.*' ota_v0/ota_update.in ota_v0/ota_compatibility.in >/dev/null
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

	# expected size and md5 of the whole rootfs
	WANT_SIZE=$(awk -F= '/^img_name=/{n=$2} n=="rootfs.squashfs" && /^img_size=/{print $2; exit}' "$OTA/ota_update.in" | tr -d '\r ')
	WANT_MD5=$(awk -F= '/^img_name=/{n=$2} n=="rootfs.squashfs" && /^img_md5=/{print $2; exit}' "$OTA/ota_update.in" | tr -d '\r ')
	[ -n "$WANT_SIZE" ] && [ -n "$WANT_MD5" ] || { echo "  no rootfs.squashfs entry in ota_update.in" >&2; exit 1; }

	# join the chunks in order (NNNN sorts as a number with fixed width)
	SQ=$TMP/rootfs.squashfs
	CHUNKS=$(ls "$OTA"/rootfs.squashfs.* | sort)
	echo "  joining $(echo "$CHUNKS" | wc -l) chunks"
	# shellcheck disable=SC2086
	cat $CHUNKS > "$SQ"
	SIZE=$(stat -c %s "$SQ")
	MD5=$(md5sum "$SQ" | cut -d' ' -f1)
	if [ "$SIZE" != "$WANT_SIZE" ] || [ "$MD5" != "$WANT_MD5" ]; then
		echo "  rootfs.squashfs is $SIZE bytes, md5 $MD5; ota_update.in says $WANT_SIZE, $WANT_MD5" >&2
		exit 1
	fi
	echo "  rootfs.squashfs: $SIZE bytes, md5 ok"

	unpack_squashfs "$SQ" "$OUT/$MODEL/rootfs"
	rm -f "$SQ"
done

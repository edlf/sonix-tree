#!/bin/bash
# Packs a recovery root fs (rootfs2) with Zee's Recovery in place of HiBy's
# recoveryd:
#
#   ./extract_firmware.sh --recovery ~/r1-mtd r1   (once: the stock recovery)
#   make -C recovery MODEL=r1                      (the app)
#   ./pack_recovery.sh r1                          -> output/r1/rootfs2-recovery.squashfs
#   ./pack_recovery.sh --kernel r1                 the same for the Sonix kernel, and
#                                                  output/r1/kernel2-recovery.xImage
#
# (build_recovery.sh runs all of it.)
#
# --kernel: the recovery runs the Sonix kernel (output/<model>/xImage, from
# ./build_images.sh) instead of the stock one in kernel2. The kernel modules
# then have to be the ones built with it, and the Sonix kernel has many
# drivers built in that the stock root fs loads as modules (keys,
# backlight, GPIO, I2C...). So module_driver/ is put together here, the way
# the Sonix firmware packer does it for the main system, from what
# ./build_images.sh leaves in output/<model>/:
#   - the stock recovery's module_driver/
#   - recovery/overlay/<model>/: the loader scripts the Sonix firmware
#     changes (driver_default_init_script.sh and the scripts it gained) and
#     /etc/init.d/S43wifi_bcm_init_config, the Wi-Fi power setup they go with
#   - every .ko in output/<model>/modules/, built with this kernel
#   - then without each module output/<model>/modules.builtin names: its .ko,
#     the script that only insmods it, and that script's line in
#     driver_default_init_script.sh
# The kernel is copied to output/<model>/kernel2-recovery.xImage. Flash the
# two together: these modules with the stock kernel2, or the stock modules
# with this kernel, leave the recovery without keys or a screen.
#
# The stock recovery root fs, extracted_assets/<model>/recovery-rootfs/, is
# copied into build/recovery-<model>/rootfs/ with:
#   /usr/bin/zees_recovery                  recovery/build/<model>/zees_recovery
#   /etc/init.d/S92_03_start_recovery        starts it instead of recoveryd,
#                                            and again whenever it exits
#   /usr/share/zees-recovery/default.otf    MiSans Regular
#                                            (recovery/assets/fonts); without
#                                            it the app falls back to its
#                                            built-in font
#   /usr/share/zees-recovery/u-boot-hiby_<model>.bin (+ .md5)
#                                            Zee's bootloader, for the
#                                            recovery's "Install fastboot"
#                                            (output/<model>/, from
#                                            ./build_images.sh). The base
#                                            image, partition table area
#                                            blank: the recovery copies the
#                                            player's own table in. R1 only
#                                            (see recovery/src/model.h); left
#                                            out, with a warning, when it has
#                                            not been built.
# Then it is trimmed: HiBy's recoveryd, and the Bluetooth, D-Bus (with
# sys_server), time sync and audio stacks go, with the time zones, web pages
# and GLib/XML/locale data, and every shared library nothing left links to
# (the TRIM list below). Wi-Fi stays. Everything else is left as it is, and
# packed like the stock one: squashfs, lzo, 128 KiB blocks, all files root's.
#
# The result has to fit the rootfs2 partition, 0x1800000 bytes (24 MiB).
# Flash it with the fastboot of Zee's bootloader:
#   fastboot flash rootfs2 output/<model>/rootfs2-recovery.squashfs
#   fastboot flash kernel2 output/<model>/kernel2-recovery.xImage   (--kernel)
# or from a root shell on the player (the second "rootfs" in /proc/mtd, mtd4
# on the R1):
#   flash_erase /dev/mtd4 0 0 && nandwrite -p /dev/mtd4 rootfs2-recovery.squashfs
# Nothing in this script touches a device.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PART_SIZE=$((0x1800000))

die() { echo "error: $*" >&2; exit 1; }

WITH_KERNEL=0
if [ "${1:-}" = --kernel ]; then
	WITH_KERNEL=1
	shift
fi
[ $# -eq 1 ] || die "usage: $0 [--kernel] r1|r3proii"
MODEL=$1
case $MODEL in r1|r3proii) ;; *) die "unknown model: $MODEL" ;; esac

STOCK=$HERE/extracted_assets/$MODEL/recovery-rootfs
APP=$HERE/recovery/build/$MODEL/zees_recovery
STAGE=$HERE/build/recovery-$MODEL
OUT=$HERE/output/$MODEL/rootfs2-recovery.squashfs
KOUT=$HERE/output/$MODEL/kernel2-recovery.xImage
KERNEL_PART_SIZE=$((0x500000))

command -v mksquashfs >/dev/null || die "mksquashfs is needed (squashfs-tools)"
[ -x "$STOCK/usr/bin/recoveryd" ] ||
	die "no stock recovery in ${STOCK#"$HERE"/}: run ./extract_firmware.sh --recovery DUMP $MODEL"
[ -f "$APP" ] || die "no ${APP#"$HERE"/}: run make -C recovery MODEL=$MODEL"

echo "=== staging ${STAGE#"$HERE"/}/rootfs"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$STOCK" "$STAGE/rootfs"
R=$STAGE/rootfs

# drop_builtin_modules MD LIST: every module in LIST (output/<model>/
# modules.builtin, one name per line) that has MD/<name>.ko goes, with the
# MD/*.sh whose only job is to insmod it and that script's `sh <script>` line
# in driver_default_init_script.sh: the kernel would refuse the .ko anyway. A
# script that does more than that insmod is kept, with a warning. The same
# rules as the Sonix firmware packer's.
drop_builtin_modules() {
	local md=$1 list=$2 name f ko kore sh shre other n=0
	local drv_list=$md/driver_default_init_script.sh
	while IFS= read -r name; do
		name=$(echo "${name%%#*}" | tr -d ' \t\r' | tr - _) # - and _ are the same in module names
		[ -n "$name" ] || continue
		ko=
		for f in "$md"/*.ko; do
			[ -e "$f" ] && [ "$(basename "$f" .ko | tr - _)" = "$name" ] && { ko=$f; break; }
		done
		[ -n "$ko" ] || continue
		rm -f "$ko"
		n=$((n + 1))
		kore=$(basename "$ko" | sed 's/\./\\./g')
		for sh in "$md"/*.sh; do
			[ -e "$sh" ] && [ "$sh" != "$drv_list" ] || continue
			grep -qE "insmod[[:space:]]+(\./)?$kore([[:space:]]|\\\\|$)" "$sh" || continue
			other=$(awk '
				/^[[:space:]]*(#|$)/ { next }
				cont { cont = /\\[[:space:]]*$/; next }
				/^[[:space:]]*insmod[[:space:]]/ && !seen { seen = 1; cont = /\\[[:space:]]*$/; next }
				{ print }' "$sh")
			if [ -n "$other" ]; then
				echo "  warning: module_driver/$(basename "$sh") loads $(basename "$ko") (built in) but does more: kept" >&2
				continue
			fi
			rm -f "$sh"
			shre=$(basename "$sh" | sed 's/\./\\./g')
			[ -f "$drv_list" ] && sed -i -E "/^[[:space:]]*(sh|\.)[[:space:]]+(\.\/)?$shre[[:space:]]*$/d" "$drv_list"
		done
	done <"$list"
	echo "  $n modules the kernel has built in removed, with their loader scripts"
}

if [ $WITH_KERNEL = 1 ]; then
	# The Sonix kernel's modules, put together here as the Sonix firmware
	# packer does for the main system: the stock recovery's module_driver/,
	# the loader scripts and Wi-Fi power setup from recovery/overlay/<model>/,
	# every .ko built with the kernel, and then without what the kernel has
	# built in.
	OUTK=$HERE/output/$MODEL
	XIMAGE=$OUTK/xImage
	OVERLAY=$HERE/recovery/overlay/$MODEL
	for f in "$XIMAGE" "$OUTK/modules.builtin"; do
		[ -f "$f" ] || die "no ${f#"$HERE"/}: run ./build_images.sh --kernel-only $MODEL"
	done
	[ -d "$OUTK/modules" ] || die "no ${OUTK#"$HERE"/}/modules/: run ./build_images.sh --kernel-only $MODEL"
	[ -d "$OVERLAY/module_driver" ] || die "no ${OVERLAY#"$HERE"/}/module_driver/"
	[ "$(stat -c %s "$XIMAGE")" -le $KERNEL_PART_SIZE ] || die "${XIMAGE#"$HERE"/} does not fit kernel2"
	echo "=== the Sonix kernel's modules"
	MD=$R/module_driver
	cp -a "$OVERLAY"/. "$R"/
	nko=0
	for ko in "$OUTK"/modules/*.ko; do
		[ -e "$ko" ] || continue
		install -m 0755 "$ko" "$MD/" # as in the Sonix firmware
		nko=$((nko + 1))
	done
	echo "  $nko modules from ${OUTK#"$HERE"/}/modules, scripts from ${OVERLAY#"$HERE"/}"
	drop_builtin_modules "$MD" "$OUTK/modules.builtin"
	echo "  module_driver/: $(ls "$MD" | wc -l) files"
fi

# unsquashfs run as a normal user drops the setuid bit busybox has in the
# stock image.
for f in bin/busybox; do
	[ -f "$R/$f" ] && chmod 4755 "$R/$f"
done

install -m 0755 "$APP" "$R/usr/bin/zees_recovery"
FONT=$HERE/recovery/assets/fonts/default.otf
mkdir -p "$R/usr/share/zees-recovery"
if [ -f "$FONT" ]; then
	install -m 0644 "$FONT" "$R/usr/share/zees-recovery/default.otf"
	echo "  bundled the MiSans font ($(stat -c %s "$FONT") bytes)"
else
	echo "  warning: no ${FONT#"$HERE"/}: the recovery will use its built-in font" >&2
fi

UBOOT=$HERE/output/$MODEL/u-boot-hiby_$MODEL.bin
if [ "$MODEL" != r1 ]; then
	echo "  no bootloader bundled: installing it is R1 only for now"
elif [ ! -f "$UBOOT" ]; then
	echo "  warning: no ${UBOOT#"$HERE"/} (./build_images.sh): \"Install fastboot\" will not be offered" >&2
else
	# the SPL header the boot ROM wants, and a blank partition table area
	[ "$(head -c 8 "$UBOOT" | od -An -tx1 | tr -d ' \n')" = 060504030255aa55 ] ||
		die "${UBOOT#"$HERE"/} does not start with an SPL header"
	[ "$(dd if="$UBOOT" bs=1 skip=$((0x5800)) count=1024 2>/dev/null | tr -d '\377' | wc -c)" = 0 ] ||
		die "${UBOOT#"$HERE"/} has a partition table in it (use the base image, not -withparts)"
	mkdir -p "$R/usr/share/zees-recovery"
	install -m 0644 "$UBOOT" "$R/usr/share/zees-recovery/"
	md5sum "$UBOOT" | cut -d' ' -f1 >"$R/usr/share/zees-recovery/u-boot-hiby_$MODEL.bin.md5"
	echo "  bundled ${UBOOT#"$HERE"/} ($(stat -c %s "$UBOOT") bytes)"
fi

cat >"$R/etc/init.d/S92_03_start_recovery" <<'EOF'
#!/bin/sh
#
# Start Zee's Recovery (in place of HiBy's /usr/bin/recoveryd, removed),
# and again if it ever exits, so the screen is never left frozen.
#

(
	while true; do
		/usr/bin/zees_recovery
		echo "zees_recovery exited ($?), restarting" >/dev/console
		sleep 1
	done
) &

exit 0
EOF
chmod 0755 "$R/etc/init.d/S92_03_start_recovery"

# What the recovery has no use for: HiBy's old recovery app, and the
# Bluetooth, D-Bus, time sync and audio stacks with their data and config,
# and HiBy's OTA scripts
# (the stock image does not even have dbus-daemon, bluetoothd or bt_init, so
# S30dbus and S80_bt_init only failed). sys_server is HiBy's
# Wi-Fi/Bluetooth/D-Bus service for the player; nothing here talks to it.
# Wi-Fi stays. Then every shared library that nothing left links to.
echo "=== trimming"
before=$(du -sk "$R" | cut -f1)
TRIM=(
	# the old recovery app (S92_03_start_recovery starts zees_recovery)
	usr/bin/recoveryd
	# Bluetooth
	etc/init.d/S80_bt_init etc/bluetooth var/lib/bluetooth usr/libexec/bluetooth usr/lib/bluez
	lib/firmware/bt_bcm
	usr/bin/bluealsa usr/bin/bluealsa-aplay usr/bin/bluealsa-cli usr/bin/bluealsa_profile
	usr/bin/bluealsa-rfcomm usr/bin/bluemoon usr/bin/bt-adapter usr/bin/btattach usr/bin/bt_disable
	usr/bin/bt_done usr/bin/bt_enable usr/bin/bt_enable_aic.sh usr/bin/bt_enable_bsa.sh usr/bin/bt_resume
	usr/bin/bt_suspend usr/bin/bt_test usr/bin/hcitop usr/bin/l2ping usr/bin/mpris-proxy usr/bin/rctest
	usr/bin/rfcomm usr/bin/sbcdec usr/bin/sbcenc usr/bin/sbcinfo
	# D-Bus, and sys_server
	etc/init.d/S30dbus etc/dbus-1 var/lib/dbus usr/share/dbus-1 usr/libexec/dbus-daemon-launch-helper
	usr/bin/dbus-binding-tool usr/bin/dbus-cleanup-sockets usr/bin/dbus-launch usr/bin/dbus-monitor
	usr/bin/dbus-run-session usr/bin/dbus-send usr/bin/dbus-test-tool
	usr/bin/dbus-update-activation-environment usr/bin/dbus-uuidgen usr/bin/gdbus
	etc/init.d/S50sys_server usr/bin/sys_server
	# time sync
	etc/init.d/S49ntp etc/ntp.conf usr/sbin/ntpd usr/bin/ntpdate
	# audio
	etc/alsa var/lib/alsa usr/share/alsa usr/lib/alsa-lib
	usr/bin/alsamixer usr/bin/amixer usr/bin/aplay usr/bin/arecord usr/bin/aserver usr/sbin/alsactl
	# HiBy's OTA scripts, card and network alike: zees_recovery checks and
	# writes packages itself (recovery/src/update.c)
	etc/ota_bin etc/ota_info
	# data files: time zones, the web pages (and their server), GLib/XML/locale data
	usr/share/zoneinfo usr/share/web etc/thttpd.conf usr/bin/thttpd
	usr/share/glib-2.0 usr/share/xml usr/share/gettext usr/share/locale
)
for f in "${TRIM[@]}"; do
	rm -rf "${R:?}/$f"
done

# Shared libraries: kept when an ELF file left in the image needs them,
# directly or through another library. glibc loads some by name at run time
# (the NSS modules, libgcc_s for thread exit and cancellation), so those stay
# too, as does the dynamic loader itself.
is_elf() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
is_lib() { case $1 in "$R"/lib/firmware/*) return 1 ;; "$R"/lib/*.so* | "$R"/usr/lib/*.so*) return 0 ;; esac; return 1; }
lib_path() { # soname -> the real file, or nothing
	local d
	for d in "$R/lib" "$R/usr/lib"; do
		[ -e "$d/$1" ] && { realpath "$d/$1"; return 0; }
	done
	return 0 # not in the image: nothing to keep
}
declare -A NEED=()
queue=()
for f in "$R"/lib/ld-*.so* "$R"/lib/libgcc_s.so* "$R"/lib/libnss_*.so*; do
	[ -e "$f" ] && queue+=("$(realpath "$f")")
done
while IFS= read -r -d '' f; do
	is_lib "$f" || { is_elf "$f" && queue+=("$f"); }
done < <(find "$R" -type f -print0)
declare -A SEEN=()
while [ ${#queue[@]} -gt 0 ]; do
	f=${queue[-1]}
	unset 'queue[-1]'
	[ -n "${SEEN[$f]:-}" ] && continue
	SEEN[$f]=1
	is_lib "$f" && NEED[$f]=1
	while read -r so; do
		p=$(lib_path "$so")
		[ -n "$p" ] && queue+=("$p")
	done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
done
nlibs=0
while IFS= read -r -d '' f; do
	if is_lib "$f" && is_elf "$f" && [ -z "${NEED[$(realpath "$f")]:-}" ]; then
		rm -f "$f"
		nlibs=$((nlibs + 1))
	fi
done < <(find "$R/lib" "$R/usr/lib" -type f -print0)
find "$R/lib" "$R/usr/lib" -xtype l -delete # links to what went
after=$(du -sk "$R" | cut -f1)
echo "  removed ${#TRIM[@]} files and folders and $nlibs unused libraries: $((before - after)) KiB"

echo "=== packing"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
mksquashfs "$R" "$OUT" -comp lzo -b 131072 -all-root -noappend -no-progress >"$STAGE/mksquashfs.log" ||
	{ cat "$STAGE/mksquashfs.log" >&2; die "mksquashfs failed"; }
SIZE=$(stat -c %s "$OUT")
if [ "$SIZE" -gt "$PART_SIZE" ]; then
	rm -f "$OUT"
	die "the image is $SIZE bytes, over the $PART_SIZE of rootfs2"
fi
printf '  -> %s (%d bytes, %d%% of rootfs2)\n' "${OUT#"$HERE"/}" "$SIZE" $((SIZE * 100 / PART_SIZE))
if [ $WITH_KERNEL = 1 ]; then
	cp "$XIMAGE" "$KOUT"
	printf '  -> %s (%d bytes, %d%% of kernel2)\n' "${KOUT#"$HERE"/}" "$(stat -c %s "$KOUT")" \
		$(($(stat -c %s "$KOUT") * 100 / KERNEL_PART_SIZE))
else
	# a kernel from an earlier --kernel run would not go with this root fs
	rm -f "$KOUT"
fi

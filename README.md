# Sonix Tree

## Zee's Recovery

A replacement for HiBy's recovery app (`recoveryd`), run by the recovery
system (kernel2 + rootfs2). It installs `.upt` firmware from the microSD
card, backs up and restores partitions, does factory resets and can install
Zee's bootloader for USB fastboot. Source and details:
[recovery/README.md](recovery/README.md).

Build it for a player (R1 by default):

```
./build_recovery.sh
```

This writes `output/<model>/kernel2-recovery.xImage` and
`output/<model>/rootfs2-recovery.squashfs`. Flash them together, from the
fastboot of Zee's bootloader (hold Play/Pause at power-on):

```
./flash_recovery.sh            # r1; flashes kernel2 + rootfs2, then starts the recovery
```

## Sonix firmware

```
./build_images.sh --kernel-only r1   # the kernel and its modules (output/r1/)
./pack_firmware.sh                   # output/<model>/<model>.upt, for both players
```

Besides the `.upt` (install it from the card with the recovery),
`pack_firmware.sh` leaves the system's two images, taken back out of that
`.upt` so they always go together: `output/<model>/kernel-system.xImage` and
`output/<model>/rootfs-system.squashfs`. To flash them with fastboot instead:

```
./flash_system.sh              # r1; flashes kernel + rootfs, then reboots
./flash_system.sh --erase-ota  # the same, and erases the ota partition first
```

If the boot record says recovery (`ota:kernel2`, as after an update that did
not finish), the player starts the recovery after flashing; `--erase-ota`
makes the next boot the system (it also clears the boot logo choice). Both
scripts take `r3proii` too, and `--no-reboot` to stay in fastboot.

On the player the app is `/usr/bin/zees_recovery`, its data is in
`/usr/share/zees-recovery/`, and it logs to `/tmp/zees_recovery.log`.
Volume up at power-on boots into it.

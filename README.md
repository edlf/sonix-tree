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
fastboot flash kernel2 output/r1/kernel2-recovery.xImage
fastboot flash rootfs2 output/r1/rootfs2-recovery.squashfs
```

On the player the app is `/usr/bin/zees_recovery`, its data is in
`/usr/share/zees-recovery/`, and it logs to `/tmp/zees_recovery.log`.
Volume up at power-on boots into it.

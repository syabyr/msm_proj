# p21 root filesystem (Alpine) + kernel image

Boots the W1A with **`/dev/mmcblk0p21` as the root filesystem** (the
1.2 GiB `system` partition) instead of the usual `p33` (`userdata`).

**WARNING: this overwrites the stock Android `system` partition (p21).**
There is currently no p21 backup in the tree — take one before writing:

```bash
ssh root@192.168.2.1 'dd if=/dev/mmcblk0p21 bs=1M' > p21-stock-system.img
```

## Build

```bash
# kernel must already be built in ../ml-out
./build-p21.sh
```

Outputs:

| file | size | notes |
|---|---|---|
| `out/kernel.img` | ~10.8 MiB | Android boot v1, no ramdisk, cmdline `... root=/dev/mmcblk0p21 rootwait rw w1a.no_dsi_pa ...` |
| `out/rootfs.img` | 128 MiB | ext4, label `w1a-alpine-p21`; **grown in place** to p21's 1.2 GiB after writing (`P21_IMG_KIB` overrides the size) |
| `out/rootfs.img.xz` | ~10 MiB | compressed artifact committed to `msm_proj/cmcc-w1a/alpine/` (the raw 128 MiB image is gitignored) |

The rootfs is built with the same `apk-tools-static --usermode` method as
`../recovery/`, then packed with `mke2fs -d` (no root required; sudo is
used only for the root ownership and the 128 MiB image).

## Flash / boot

Writing p21 needs p21 **unmounted** and `resize2fs`; the p33 system mounts
p21 at `/mnt/system` and lacks `resize2fs`, so do it from the **recovery**:

```bash
../recovery/boot-recovery.sh     # fastboot boot the recovery (p21 unmounted)
./flash-p21.sh                   # dd rootfs.img -> p21, e2fsck + resize2fs
fastboot boot out/kernel.img     # boot the new p21 rootfs
```

Manual equivalent (from the recovery):

```bash
cat out/rootfs.img | ssh root@192.168.2.1 'dd of=/dev/mmcblk0p21 bs=1M'
ssh root@192.168.2.1 'e2fsck -f /dev/mmcblk0p21 && resize2fs /dev/mmcblk0p21'
```

The kernel image can also be persisted at p20+512K (lk2nd is
forced-fastboot, so you still `fastboot boot` from the host):

```bash
cat out/kernel.img | ssh root@192.168.2.1 'dd of=/dev/mmcblk0p20 bs=4096 seek=128 conv=notrunc'
```

The kernel mounts p21, runs `/sbin/init` (busybox) → `/etc/inittab`
`::sysinit:/etc/w1a-init.sh`, which brings up:

- USB **CDC-NCM + CDC-ACM** composite (`w1a.no_dsi_pa`, 192.168.2.1)
- telnet `:2323`, ssh `:22` (root, key from `overlay/root/.ssh/authorized_keys`)
- serial console on `/dev/ttyGS0`
- WiFi (`wlan0`) using `/etc/wpa_supplicant/w1a.conf`
- WCNSS firmware staged from p1/p22 at boot
- audio mixer defaults (sndmix), vibration etc.

## Files

```
alpine/
├── build-p21.sh        # build pipeline
├── packages.txt        # Alpine package list (armv7)
├── overlay/            # copied over the apk rootfs
│   ├── etc/{inittab,fstab,hostname,w1a-init.sh}
│   └── root/.ssh/authorized_keys
├── w1a.conf            # optional WiFi config (gitignored, credentials)
└── out/{kernel.img,rootfs.img}
```

## Revert

- Restore the p21 backup: `cat p21-stock-system.img | ssh ... 'dd of=/dev/mmcblk0p21 bs=1M'`.
- Or just boot the normal p33 image:
  `fastboot boot ../asteroid-mainline-w1a-usb-macos.img` — p33 is untouched.
- Recovery: `../recovery/boot-recovery.sh` (serial/ssh menu, can dd any image).

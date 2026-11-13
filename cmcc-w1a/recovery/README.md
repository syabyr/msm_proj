# W1A Recovery image

Minimal, self-contained **Alpine** recovery environment for the CMCC W1A
(MSM8909) watch, built on top of the mainline kernel from `../ml-out`
(commit `cmcc-w1a-7.0` + the USB NCM/ACM work).

Runs entirely from an initramfs (RAM); the persistent rootfs (`p33`) is
only ever mounted **read-only** unless the operator explicitly asks for a
write.  It is meant to rescue a broken rootfs/boot image and to back
up/restore any partition.

## Layout

```
recovery/
├── build-recovery.sh     # build pipeline (host side)
├── init                  # PID 1 inside the initramfs
├── menu.sh               # interactive recovery menu (serial console)
├── packages.txt          # Alpine package list (armv7)
├── machine.conf          # partition name map
├── build/                # build artifacts (rootfs, initramfs.xz, apk cache)
└── out/w1a-recovery.img  # generated Android boot v1 image
```

## Build

```bash
cd ../linux-mainline
make -j8 O=../ml-out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zImage dtbs
cd ..
bash recovery/build-recovery.sh
```

Host requirements: `curl tar cpio xz python3 qemu-arm-static`.  No root
needed: packages are installed with `apk-tools-static --usermode` and
the busybox applet links are created via `qemu-arm-static ... --list`.

Output: `recovery/out/w1a-recovery.img` (Android boot v1, ~18 MiB,
fits the 20 MiB `p24 recovery` partition).

## Boot

```bash
# RAM only, no flash - the primary and verified path
fastboot boot recovery/out/w1a-recovery.img
```

This lk2nd build is compiled with **forced fastboot mode** ("Fastboot
mode was forced with compile-time flag"): every power-on lands in
fastboot, so the recovery image is always booted with `fastboot boot`
from the host.

**Volume Up is NOT a recovery key on this device.**  The stock Qualcomm
PBL/aboot consumes Volume Up + power as the **EDL** (Emergency Download)
combo (USB `05c6:9008`), and lk2nd never runs.  Exit EDL with a ~15 s
power-button press (or `edl reset`).

The p24 `recovery` partition can hold an archival copy
(`fastboot flash recovery ...`), but on this hardware it is **not**
button-bootable.

## Access

| channel | endpoint |
|---|---|
| serial console | host `/dev/ttyACM1` @ 115200 (macOS `/dev/cu.usbmodem*`) |
| network | `usb0 = 192.168.2.1/24` (CDC-NCM, macOS/Linux免驱) |
| ssh | `ssh root@192.168.2.1` (key from the normal rootfs) |
| telnet | `telnet 192.168.2.1 2323` (root shell, no password) |
| wifi | WCNSS firmware staged from p1/p22; `wlan0` appears |

## Menu

1. shell (ash)
2. info: partitions / blkid / mounts
3. fsck read-only
4. backup partition → host (socat/nc)
5. restore partition ← host (socat/nc)
6. flash boot.img → p20@512K
7. dmesg / ramoops / recovery log
8. export file/partition over USB mass storage
9. reboot (normal / fastboot / poweroff)
d. fsck repair / danger zone (format p24/p33, wipe p24 boot.img)

## Tools

busybox (full applet set), e2fsprogs, dosfstools, mtools, mmc-utils,
util-linux, iproute2, dropbear, wpa_supplicant/iw, rsync, socat,
picocom, less, kmod, i2c-tools, procps-ng, nano, netcat-openbsd, plus
the project's static tools (mempeek, w1a-vib, i2cdetect/i2cread,
sndcap/sndmix/sndplay, fbtest, fpsdemo/fpspush, msm-fb-refresher,
w1ash, w1atest, tegate, gpupoke, mempoke).

Deliberately excluded: python3, gdb, kexec, file (10 MB magic.mgc),
zstd (C++), curl, strace, screen, openssl CLI, tzdata, pciutils.

## Gotchas (learned the hard way)

1. **configfs must be mounted on a writable path** (`/config`).  Using
   `/sys/kernel/config` fails silently (sysfs is read-only) → no gadget
   → the box is unreachable.
2. **`apk --no-scripts` skips busybox's post-install applet links**, so
   `mkdir/ln/sleep/cat/chmod/uname/hostname/reboot/...` are "command not
   found"; the init then busy-loops on a missing `sleep`.  The build
   script recreates them with `qemu-arm-static ... busybox --list`.
3. **dropbear refuses the key** because `--usermode` leaves `/root`
   owned by uid 1000; the init does `chown -R root:root /root` and
   `chmod 700/600`.
4. `/init` runs ~1.8 s after the kernel starts, **before** the async UDC
   (`ci_hdrc`) probe.  Wait for `/sys/class/udc/*` before binding.
5. The image must stay **≤ 20 MiB** to fit `p24`; the initramfs budget is
   ~9 MiB (xz -9).

## Recovery of the recovery

The normal boot image lives at `p20 + 512K`; this image goes to `p24`.
If a recovery build is bad, `fastboot boot asteroid-mainline-w1a-keepalive2.img`
(previous known-good) or restore `asteroid/backup-p20/p20-backup.bin`.

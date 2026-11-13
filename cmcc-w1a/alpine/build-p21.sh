#!/bin/bash
# build-p21.sh - build a kernel.img that roots on p21 and an Alpine rootfs.img
# for the CMCC W1A (MSM8909).
#
#   ./build-p21.sh
#   -> out/kernel.img   Android boot v1 (no ramdisk), cmdline roots on /dev/mmcblk0p21
#   -> out/rootfs.img   ext4 filesystem, exactly p21's size (1,258,292 KiB)
#
# Then (DESTRUCTIVE - overwrites the stock Android system on p21):
#   fastboot boot out/kernel.img          # RAM boot, or flash to p20@512K
#   cat out/rootfs.img | ssh root@192.168.2.1 'dd of=/dev/mmcblk0p21 bs=1M'
#
# The rootfs is built with the same apk-tools-static method as the recovery
# image, then packed into ext4 with `mke2fs -d` (no root needed on the host).
#
# Env:
#   W1A_BUILD_ROOT  build tree (default: parent of this dir)
#   W1A_KOUT        kernel output (default $W1A_BUILD_ROOT/ml-out)
#   W1A_P21_WORK    work dir (default ./build)
#   P21_KIB         rootfs size in KiB (default 1258292 = p21)
#   ALPINE_VER / ALPINE_MIRROR

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${W1A_BUILD_ROOT:-$DIR/..}"
AST="$BUILD_ROOT/asteroid"
KOUT="${W1A_KOUT:-$BUILD_ROOT/ml-out}"
WORK="${W1A_P21_WORK:-$DIR/build}"
ROOTFS="$WORK/rootfs"
OUT="$DIR/out"
APK_CACHE="${APK_CACHE:-$BUILD_ROOT/recovery/.apk-tools-static}"
ALPINE_VER="${ALPINE_VER:-v3.24}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
P21_KIB="${P21_KIB:-1258292}"       # p21 partition size (resize target)
IMG_KIB="${P21_IMG_KIB:-131072}"    # rootfs.img size (128 MiB; grown in place)

ZIMAGE="$KOUT/arch/arm/boot/zImage"
DTB="$KOUT/arch/arm/boot/dts/qcom/qcom-msm8909-cmcc-w1a.dtb"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"; }

need curl
need tar
need xz
need python3
need qemu-arm-static
need mke2fs
need ssh-keygen
[ -f "$ZIMAGE" ] || die "kernel not built: $ZIMAGE"
[ -f "$DTB" ] || die "dtb not built: $DTB"
[ -f "$AST/tools/build-boot-img-nord.sh" ] || die "missing $AST/tools/build-boot-img-nord.sh"

mkdir -p "$OUT"

# ------------------------------------------------------------ 1. kernel.img
echo "=== kernel.img (root=/dev/mmcblk0p21, no ramdisk)"
W1A_KOUT="$KOUT" W1A_OUT="$OUT/kernel.img" \
	W1A_CMD='w1a.no_dsi_pa root=/dev/mmcblk0p21 rootwait rw log_buf_len=8M ' \
	bash "$AST/tools/build-boot-img-nord.sh" >/dev/null
python3 - "$OUT/kernel.img" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(2048)
m, k, ka, r, ra, s, sa, t, pg, d, _ = struct.unpack('<8s10I', b[:48])
assert m == b'ANDROID!' and r == 0, 'bad kernel.img'
cmd = b[64:576].split(b'\0')[0].decode()
assert 'root=/dev/mmcblk0p21' in cmd, f'cmdline lacks p21: {cmd}'
print('kernel.img ok:', k, 'bytes, cmdline:', cmd)
PY

# ------------------------------------------------------------- 2. apk.static
if [ ! -x "$APK_CACHE/sbin/apk.static" ]; then
	echo "=== fetching apk-tools-static"
	mkdir -p "$APK_CACHE"
	url="$ALPINE_MIRROR/$ALPINE_VER/main/x86_64"
	f=$(curl -fsS --max-time 15 "$url/" | grep -o 'apk-tools-static-[^"]*\.apk' | head -1)
	[ -n "$f" ] || die "cannot find apk-tools-static at $url"
	( cd "$APK_CACHE" && curl -fsS --max-time 120 -O "$url/$f" && tar -xzf "$f" )
fi
APK="$APK_CACHE/sbin/apk.static"
"$APK" --version >/dev/null || die "apk.static not runnable"

# -------------------------------------------------------------- 3. rootfs
PKGS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$DIR/packages.txt" | tr '\n' ' ')
echo "=== installing Alpine $ALPINE_VER rootfs (armv7)"
if [ -e "$WORK" ]; then
	rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK"
fi
mkdir -p "$ROOTFS"
"$APK" --usermode --root "$ROOTFS" --arch armv7 --initdb \
	--no-scripts --allow-untrusted -U \
	-X "$ALPINE_MIRROR/$ALPINE_VER/main" \
	-X "$ALPINE_MIRROR/$ALPINE_VER/community" \
	add $PKGS

# busybox applet symlinks (apk --no-scripts skips the post-install)
echo "=== busybox applets"
for a in $(qemu-arm-static -L "$ROOTFS" "$ROOTFS/bin/busybox" --list); do
	found=
	for d in bin sbin usr/bin usr/sbin; do
		[ -e "$ROOTFS/$d/$a" ] && { found=1; break; }
	done
	[ -n "$found" ] || ln -sf /bin/busybox "$ROOTFS/bin/$a"
done
for a in init reboot poweroff halt shutdown; do
	[ -e "$ROOTFS/sbin/$a" ] || ln -sf /bin/busybox "$ROOTFS/sbin/$a"
done
# busybox-extras applets used by w1a-init.sh
for a in udhcpd telnetd; do
	[ -x "$ROOTFS/bin/busybox-extras" ] && \
		ln -sf /bin/busybox-extras "$ROOTFS/usr/sbin/$a"
done

# ------------------------------------------------------------- 4. overlay
echo "=== overlaying userspace"
cp -a "$DIR/overlay/." "$ROOTFS/"
chmod 755 "$ROOTFS/etc/w1a-init.sh"
chmod 600 "$ROOTFS/root/.ssh/authorized_keys" 2>/dev/null || true
chown -R root:root "$ROOTFS/root" 2>/dev/null || true

# project static tools used by w1a-init.sh (audio) and for debugging
mkdir -p "$ROOTFS/usr/bin"
for t in sndmix sndplay w1a-vib mempeek i2cdetect fbtest; do
	[ -x "$BUILD_ROOT/recovery/tools/$t" ] && \
		install -m755 "$BUILD_ROOT/recovery/tools/$t" "$ROOTFS/usr/bin/$t"
done

# ssh host keys (openssh post-install is skipped)
mkdir -p "$ROOTFS/etc/ssh"
[ -f "$ROOTFS/etc/ssh/ssh_host_ed25519_key" ] || \
	ssh-keygen -q -t ed25519 -N '' -f "$ROOTFS/etc/ssh/ssh_host_ed25519_key"
[ -f "$ROOTFS/etc/ssh/ssh_host_ecdsa_key" ] || \
	ssh-keygen -q -t ecdsa -N '' -f "$ROOTFS/etc/ssh/ssh_host_ecdsa_key"
chmod 600 "$ROOTFS/etc/ssh/"ssh_host_*_key

# WiFi credentials: never committed.  Copy from ./w1a.conf if present,
# else from the running device, else leave none (USB SSH still works).
mkdir -p "$ROOTFS/etc/wpa_supplicant"
if [ -f "$DIR/w1a.conf" ]; then
	cp "$DIR/w1a.conf" "$ROOTFS/etc/wpa_supplicant/w1a.conf"
elif ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
	 -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
	 root@192.168.2.1 'cat /etc/wpa_supplicant/w1a.conf' \
	 > "$ROOTFS/etc/wpa_supplicant/w1a.conf" 2>/dev/null; then
	:
else
	echo "WARN: no WiFi config (add $DIR/w1a.conf to enable wlan0)"
fi
printf 'nameserver 223.5.5.5\n' > "$ROOTFS/etc/resolv.conf"

# apk --usermode leaves everything owned by the build user; a real rootfs
# must be root-owned or sshd's StrictModes rejects authorized_keys.
MKFS="mke2fs"
if sudo -n true 2>/dev/null; then
	sudo -n chown -R 0:0 "$ROOTFS"
	MKFS="sudo -n mke2fs"       # mke2fs must read the root-owned /root
else
	echo "WARN: no passwordless sudo; rootfs stays owned by $(id -un)." >&2
	echo "      sshd may reject the key - run: sudo chown -R 0:0 $ROOTFS" >&2
fi
if sudo -n true 2>/dev/null; then
	sudo -n chmod 700 "$ROOTFS/root" "$ROOTFS/root/.ssh"
	sudo -n chmod 600 "$ROOTFS/root/.ssh/authorized_keys"
else
	chmod 700 "$ROOTFS/root" "$ROOTFS/root/.ssh" 2>/dev/null || true
	chmod 600 "$ROOTFS/root/.ssh/authorized_keys" 2>/dev/null || true
fi

# ------------------------------------------------------- 5. ext4 rootfs.img
# The image only needs to hold the rootfs, not the whole partition: write
# this small image, then `resize2fs /dev/mmcblk0p21` grows it to P21_KIB.
echo "=== packing rootfs.img (${IMG_KIB} KiB, ext4, mke2fs -d)"
BLOCKS=$((IMG_KIB / 4))
rm -f "$OUT/rootfs.img"
$MKFS -q -F -t ext4 -b 4096 -L w1a-alpine-p21 -d "$ROOTFS" \
	"$OUT/rootfs.img" "$BLOCKS"
[ "$(id -u)" -ne 0 ] && sudo -n chown "$(id -u):$(id -g)" "$OUT/rootfs.img" 2>/dev/null || true

# Compressed artifact for the repo (the raw image is 128 MiB).
if command -v xz >/dev/null 2>&1; then
	echo "=== compressing rootfs.img.xz"
	xz -9 -T0 -c "$OUT/rootfs.img" > "$OUT/rootfs.img.xz"
fi

# ------------------------------------------------------------- 6. report
echo
echo "=== outputs"
ls -la "$OUT/kernel.img" "$OUT/rootfs.img"
echo "rootfs.img filesystem:"
dumpe2fs -h "$OUT/rootfs.img" 2>/dev/null | grep -E 'Filesystem volume name|Block count|Block size|Filesystem state' || true
echo
echo "Write the rootfs to p21 and grow it to ${P21_KIB} KiB (DESTROYS the stock Android system):"
echo "  cat $OUT/rootfs.img | ssh root@192.168.2.1 'dd of=/dev/mmcblk0p21 bs=1M'"
echo "  ssh root@192.168.2.1 'e2fsck -f /dev/mmcblk0p21 && resize2fs /dev/mmcblk0p21'"
echo "or:"
echo "  alpine/flash-p21.sh"
echo "Boot it:"
echo "  fastboot boot $OUT/kernel.img"

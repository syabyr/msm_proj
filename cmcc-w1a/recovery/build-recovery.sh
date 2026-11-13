#!/bin/bash
# build-recovery.sh - assemble the W1A Alpine recovery boot image.
#
# Output: an Android boot v1 image (zImage + W1A DTB + Alpine initramfs)
# that can be:
#   fastboot boot w1a-recovery.img          (RAM only, no flash)
#   fastboot flash recovery w1a-recovery.img (p24, Volume Up recovery)
#
# The initramfs is an Alpine armv7 rootfs installed on the build host with
# apk-tools-static (packages are only unpacked, scripts are skipped).
# Recovery userspace overlay comes from this directory.
#
# Env:
#   W1A_KOUT     kernel output dir (default ../ml-out)
#   W1A_OUT      output image (default recovery/out/w1a-recovery.img)
#   ALPINE_VER   Alpine branch (default v3.24)
#   ALPINE_MIRROR mirror base (default tsinghua)
#   W1A_REC_WORK build work dir (default recovery/build)
#
# Layout:
#   recovery/build-recovery.sh   this script
#   recovery/{init,menu.sh,packages.txt,machine.conf}
#   recovery/out/w1a-recovery.img
#   recovery/build/              rootfs + initramfs build artifacts

set -e

REC="$(cd "$(dirname "$0")" && pwd)"
AST="$REC/../asteroid"          # build-tree helper tools (optional)
[ -d "$AST" ] || AST=""
TOOLS="$REC/tools"              # self-contained static tools (committed)
KOUT="${W1A_KOUT:-$REC/../ml-out}"
if [ ! -f "$KOUT/arch/arm/boot/zImage" ]; then
	# copied into the msm_proj repo: point back at the build tree
	for k in "$REC/../../../cmcc-w1a/ml-out" "$REC/../ml-out"; do
		if [ -f "$k/arch/arm/boot/zImage" ]; then KOUT="$k"; break; fi
	done
fi
WORK="${W1A_REC_WORK:-$REC/build}"
OUT="${W1A_OUT:-$REC/out/w1a-recovery.img}"
ALPINE_VER="${ALPINE_VER:-v3.24}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
APK_CACHE="${APK_CACHE:-$REC/.apk-tools-static}"

ZIMAGE="$KOUT/arch/arm/boot/zImage"
DTB="$KOUT/arch/arm/boot/dts/qcom/qcom-msm8909-cmcc-w1a.dtb"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"; }

need curl
need tar
need cpio
need xz
need python3
need qemu-arm-static
[ -f "$ZIMAGE" ] || die "kernel not built: $ZIMAGE (run tools/build-kernel.sh)"
[ -f "$DTB" ]    || die "dtb not built: $DTB"

# ------------------------------------------------------------------ 1. apk
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

# -------------------------------------------------------------- 2. rootfs
PKGS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REC/packages.txt" | tr '\n' ' ')
echo "=== installing Alpine $ALPINE_VER rootfs (armv7)"
rm -rf "$WORK"
mkdir -p "$WORK/rootfs"
# --usermode: unpack as the current user, no root/sudo needed.  The
# initramfs runs as PID 1 (root) regardless of on-disk ownership.
"$APK" --usermode --root "$WORK/rootfs" --arch armv7 --initdb \
	--no-scripts --allow-untrusted -U \
	-X "$ALPINE_MIRROR/$ALPINE_VER/main" \
	-X "$ALPINE_MIRROR/$ALPINE_VER/community" \
	add $PKGS

# --------------------------------------------------------------- 3. overlay
echo "=== overlaying recovery userspace"
install -Dm755 "$REC/init"       "$WORK/rootfs/init"
install -Dm755 "$REC/menu.sh"    "$WORK/rootfs/recovery/menu.sh"
install -Dm644 "$REC/machine.conf" "$WORK/rootfs/etc/machine.conf"

# Trim anything the recovery does not need (size budget for p24).
rm -rf "$WORK/rootfs/var/cache/apk"/* \
       "$WORK/rootfs/usr/share/man"/* \
       "$WORK/rootfs/usr/share/doc"/* \
       "$WORK/rootfs/usr/share/locale"/* \
       "$WORK/rootfs/usr/share/hwdata" \
       "$WORK/rootfs/usr/share/zoneinfo" \
       "$WORK/rootfs/etc/init.d" \
       "$WORK/rootfs/etc/runlevels" \
       "$WORK/rootfs/lib/rc" 2>/dev/null || true
rm -f "$WORK/rootfs/sbin/eapol_test" "$WORK/rootfs/usr/sbin/eapol_test" \
      "$WORK/rootfs/usr/share/misc/magic.mgc" 2>/dev/null || true

# project tools from the previous initramfs (static ARM binaries) and the
# tools/ build dir; static so they run regardless of the rootfs libc.
for t in mempeek w1a-vib i2cdetect i2cread sndcap sndmix sndplay \
	 fbtest fpsdemo fpspush msm-fb-refresher w1ash w1atest tegate \
	 gpupoke mempoke; do
	src=""
	[ -x "$TOOLS/$t" ] && src="$TOOLS/$t"
	if [ -z "$src" ] && [ -n "$AST" ]; then
		[ -x "$AST/tmp/rd/usr/bin/$t" ] && src="$AST/tmp/rd/usr/bin/$t"
		[ -z "$src" ] && [ -x "$AST/tools/$t" ] && src="$AST/tools/$t"
	fi
	[ -n "$src" ] && install -Dm755 "$src" "$WORK/rootfs/usr/bin/$t"
done

# busybox-extras applet symlinks: post-install scripts are skipped with
# --no-scripts, so create the ones the recovery init uses.
for a in udhcpd telnetd; do
	[ -x "$WORK/rootfs/bin/busybox-extras" ] && \
		ln -sf /bin/busybox-extras "$WORK/rootfs/usr/sbin/$a"
done

# busybox applet symlinks: apk --no-scripts also skips the busybox
# post-install that normally creates every applet link.  Without them
# mkdir/ln/sleep/cat/chmod/uname/hostname/... are "command not found",
# the init silently does nothing and the box never comes up on USB.
if [ -x "$WORK/rootfs/bin/busybox" ]; then
	echo "=== creating busybox applet symlinks"
	for a in $(qemu-arm-static -L "$WORK/rootfs" \
			"$WORK/rootfs/bin/busybox" --list); do
		found=
		for d in bin sbin usr/bin usr/sbin; do
			[ -e "$WORK/rootfs/$d/$a" ] && { found=1; break; }
		done
		[ -n "$found" ] || ln -sf /bin/busybox "$WORK/rootfs/bin/$a"
	done
fi

mkdir -p "$WORK/rootfs/etc/dropbear" "$WORK/rootfs/root/.ssh"
[ -f "$HOME/.ssh/id_ed25519.pub" ] && \
	cp "$HOME/.ssh/id_ed25519.pub" "$WORK/rootfs/root/.ssh/authorized_keys"
printf 'nameserver 223.5.5.5\n' > "$WORK/rootfs/etc/resolv.conf"
printf 'w1a-recovery\n'         > "$WORK/rootfs/etc/hostname"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$WORK/rootfs/etc/passwd.rec"

# WCNSS firmware is staged from p1/p22 at runtime (proprietary); nothing
# to bake in here.

# -------------------------------------------------------------- 4. pack
echo "=== packing initramfs (xz -9)"
( cd "$WORK/rootfs" && find . -print0 | cpio --null -o -H newc 2>/dev/null | xz -9 --check=none ) \
	> "$WORK/initramfs.xz"
ls -la "$WORK/initramfs.xz"

# -------------------------------------------------------------- 5. image
echo "=== assembling boot image"
mkdir -p "$(dirname "$OUT")"
python3 - "$ZIMAGE" "$DTB" "$WORK/initramfs.xz" "$OUT" <<'PY'
import struct, sys

zimage_f, dtb_f, rd_f, out_f = sys.argv[1:5]

zimage = open(zimage_f, 'rb').read()
assert zimage[0x24:0x28] == b'\x18\x28\x6f\x01', 'zImage magic (LE @0x24) missing'
dtb = open(dtb_f, 'rb').read()
assert struct.unpack('>I', dtb[:4])[0] == 0xd00dfeed, 'DTB magic missing'
ramdisk = open(rd_f, 'rb').read()
assert ramdisk[:6] == b'\xfd7zXZ\x00', 'initramfs is not xz'

kern = zimage + dtb + b'\x00' * 8

# factory (device-mobvoi-skipjack) Android boot v1 values
KERNEL_ADDR  = 0x80100000 + 0x00008000
RAMDISK_ADDR = 0x80100000 + 0x02000000
SECOND_ADDR  = 0x80100000 + 0x00f00000
TAGS_ADDR    = 0x80100000 + 0x01e00000
PAGE_SIZE    = 2048

hdr = bytearray(PAGE_SIZE)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<10I', hdr, 8,
                 len(kern), KERNEL_ADDR,
                 len(ramdisk), RAMDISK_ADDR,
                 0, SECOND_ADDR,
                 TAGS_ADDR, PAGE_SIZE, 0, 0)
cmd = ('w1a.no_dsi_pa console=tty0 consoleblank=0 log_buf_len=8M '
       'panic=5 lk2nd.pass-ramoops=zap androidboot.hardware=skipjack '
       'buildvariant=user selinux=0')
hdr[64:576] = cmd.encode().ljust(512, b'\x00')

img = bytes(hdr) + kern
img += b'\x00' * (PAGE_SIZE - (len(img) % PAGE_SIZE))
img += ramdisk
img += b'\x00' * (PAGE_SIZE - (len(img) % PAGE_SIZE))

open(out_f, 'wb').write(img)

# verify
m, k, ka, r, ra, s, sa, t, p, d, _ = struct.unpack('<8s10I', img[:48])
assert m == b'ANDROID!'
assert img[p+0x24:p+0x28] == b'\x18\x28\x6f\x01'
r_off = p * (1 + (k + p - 1) // p)
assert img[r_off:r_off+6] == b'\xfd7zXZ\x00', 'ramdisk not at expected offset'
fdt = len(zimage)
assert img[p+fdt:p+fdt+4] == b'\xd0\x0d\xfe\xed', 'DTB missing'
print(f'kernel {len(kern)} + ramdisk {len(ramdisk)} = {len(img)} bytes')
PY

SIZE=$(stat -c%s "$OUT")
echo "=== $OUT ($SIZE bytes)"
if [ "$SIZE" -gt $((20 * 1024 * 1024)) ]; then
	echo "WARNING: image exceeds 20 MiB -> will NOT fit p24 (Volume Up recovery)."
	echo "         It can still be used with 'fastboot boot'."
fi
echo
echo "Boot it:      fastboot boot $OUT"
echo "Persist p24:  fastboot flash recovery $OUT"

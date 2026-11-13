#!/bin/bash
# build-boot-img.sh - assemble kernel.img for the W1A boot partition (p20@512K)
#
# Usage: tools/build-boot-img.sh [output.img] [--cmdline "extra"]
#   output.img  relative (to the source root) or absolute path.
#               default: alpine/out/kernel.img
#   --cmdline   extra cmdline; default from W1A_CMD, else the p21 variant
#
# Android boot v1 image with RAMDISK_SIZE 0: the kernel mounts the root
# partition directly (default root=/dev/mmcblk0p21; set W1A_CMD for
# p33).  zImage + appended W1A DTB, so lk2nd finds the FDT at runtime.
# Flash at p20+512K or `fastboot boot` it.
#
# Requires: zImage + dtb built (tools/build-kernel.sh).

set -e

AST="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${W1A_OUT:-$AST/alpine/out/kernel.img}"
CMDLINE_DEFAULT='w1a.no_dsi_pa root=/dev/mmcblk0p21 rootwait rw log_buf_len=8M '
CMDLINE="$W1A_CMD"

while [ $# -gt 0 ]; do
    case "$1" in
        --cmdline) CMDLINE="$2"; shift 2 ;;
        *) OUT="$1"; shift ;;
    esac
done
[ -n "$CMDLINE" ] || CMDLINE="$CMDLINE_DEFAULT"

KERN="${W1A_KERNEL:-$AST/linux-mainline}"
[ -d "$KERN" ] || KERN="$AST/../linux-mainline"   # old layout fallback
KOUT="${W1A_KOUT:-$KERN/../ml-out}"
ZIMAGE="$KOUT/arch/arm/boot/zImage"
DTB="$KOUT/arch/arm/boot/dts/qcom/qcom-msm8909-cmcc-w1a.dtb"

[ -f "$ZIMAGE" ] || { echo "ERROR: $ZIMAGE missing - run tools/build-kernel.sh" >&2; exit 1; }
[ -f "$DTB" ] || { echo "ERROR: $DTB missing - run tools/build-kernel.sh" >&2; exit 1; }

python3 - "$ZIMAGE" "$DTB" "$OUT" "$CMDLINE" <<'EOF'
import struct, sys

zimage_f, dtb_f, out_f, extra = sys.argv[1:5]

zimage = open(zimage_f, 'rb').read()
assert zimage[0x24:0x28] == b'\x18\x28\x6f\x01', 'zImage magic (LE @0x24) missing'
dtb = open(dtb_f, 'rb').read()
assert struct.unpack('>I', dtb[:4])[0] == 0xd00dfeed, 'DTB magic missing'
kern = zimage + dtb + b'\x00' * 8
print(f'zImage {len(zimage)} + DTB {len(dtb)} = kernel {len(kern)}')

# --- Android boot v1 header, factory values (factory values, no stock image dependency)
KERNEL_ADDR  = 0x80100000 + 0x00008000
RAMDISK_ADDR = 0x80100000 + 0x02000000
SECOND_ADDR  = 0x80100000 + 0x00f00000
TAGS_ADDR    = 0x80100000 + 0x01e00000
PAGE_SIZE    = 2048

# ramdisk size 0: no ramdisk, p33 is the root filesystem
hdr = bytearray(PAGE_SIZE)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<10I', hdr, 8,
                 len(kern), KERNEL_ADDR,
                 0, RAMDISK_ADDR,          # ramdisk_size = 0
                 0, SECOND_ADDR,
                 TAGS_ADDR, PAGE_SIZE, 0, 0)
cmd = (extra + ' console=tty0 androidboot.hardware=skipjack buildvariant=user '
       'selinux=0 lk2nd.pass-ramoops=zap panic=5')
hdr[64:576] = cmd.encode().ljust(512, b'\x00')
print(f'cmdline: {cmd}')

img = bytes(hdr) + kern
img += b'\x00' * (PAGE_SIZE - (len(img) % PAGE_SIZE))
# no ramdisk section

open(out_f, 'wb').write(img)
print(f'wrote {out_f}: {len(img)} bytes')

# verify
m, k, ka, r, ra, s, sa, t, p, d, _ = struct.unpack('<8s10I', img[:48])
assert m == b'ANDROID!' and r == 0
assert img[p+0x24:p+0x28] == b'\x18\x28\x6f\x01', 'zImage magic missing in img'
fdt2 = len(zimage)
kernb = img[p:p+k]
assert kernb[fdt2:fdt2+4] == b'\xd0\x0d\xfe\xed', f'W1A DTB missing @{fdt2:#x}'
assert kernb[fdt2:fdt2+len(dtb)] == dtb
print(f'VERIFIED: ANDROID! header, ramdisk=0, zImage magic OK, W1A DTB intact @{fdt2:#x}')
EOF

# move to absolute path if requested
case "$OUT" in
    /*) ;;
    *) OUT="$AST/$OUT" ;;
esac
echo "=== done: $OUT"
ls -la "$OUT"

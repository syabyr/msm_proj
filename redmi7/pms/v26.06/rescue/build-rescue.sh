#!/bin/bash
# =============================================================================
# build-rescue.sh — Build debug-rescue Android boot image for pmOS 26.06
#
# Packages kernel + initramfs + DTB into an Android boot image suitable for
# lk2nd's "fastboot boot".  Appends the DTB after the gzip kernel (ARM64
# appended-DTB convention) because lk2nd requires it.
#
# The "pmos.debug-shell" cmdline arg triggers the initramfs debug hook:
#   - USB networking (172.16.42.1)
#   - telnetd on port 23
#   - root shell on serial + ttyGS0
#
# Usage:
#   ./build-rescue.sh                              # defaults
#   ./build-rescue.sh -k /path/to/vmlinuz          # custom kernel
#   ./build-rescue.sh -r /path/to/initramfs        # custom initramfs
#   ./build-rescue.sh -d /path/to/device.dtb       # custom DTB
#   ./build-rescue.sh -o my-rescue.img             # output name
#   ./build-rescue.sh -a "extra=1"                 # extra cmdline
#   ./build-rescue.sh -v                           # verbose (keep tmp files)
#
# Output:  debug-rescue-pms-26.06.img
# =============================================================================

set -euo pipefail

# ---- defaults ----
BOOT_DIR="${BOOT_DIR:-/mnt/2T/temp/build/pms/v26.06/pmbootstrap/chroot_rootfs_qcom-msm8953/boot}"
KERNEL="${BOOT_DIR}/vmlinuz"
INITRAMFS="${BOOT_DIR}/initramfs"
DTB="${BOOT_DIR}/sdm632-xiaomi-onclite.dtb"
OUTPUT="./debug-rescue-pms-26.06.img"

# Android boot image layout (Qualcomm msm8953)
KERNEL_ADDR=0x80008000
RAMDISK_ADDR=0x81000000
TAGS_ADDR=0x80000100
PAGE_SIZE=2048

# match the running pmOS install so rootfs can be found after debug shell exits
CMDLINE="quiet splash plymouth.ignore-serial-consoles plymouth.prefer-fbcon loglevel=2 pmos_boot_uuid=599dc14c-bb85-49ba-bdb4-64731b4b80bf pmos_root_uuid=0a374d11-e532-41b5-96a8-db1338fa0a01 pmos_rootfsopts=defaults pmos.debug-shell"

VERBOSE=0

# ---- parse args ----
while getopts "k:r:d:o:a:vh" opt; do
    case "$opt" in
        k) KERNEL="$OPTARG" ;;
        r) INITRAMFS="$OPTARG" ;;
        d) DTB="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        a) CMDLINE_EXTRA="$OPTARG" ;;
        v) VERBOSE=1 ;;
        h) sed -n '2,26p' "$0" ; exit 0 ;;
        *) echo "Usage: $0 [-k kernel] [-r initramfs] [-d dtb] [-o out.img] [-a extra_cmdline]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))
CMDLINE="${CMDLINE} ${CMDLINE_EXTRA:-}"

# ---- checks ----
for f in "$KERNEL" "$INITRAMFS" "$DTB"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: file not found: $f" >&2; exit 1
    fi
done

echo "=== Build Rescue Boot Image ==="
echo "  Kernel:    $KERNEL        ($(du -h "$KERNEL" | cut -f1))"
echo "  Initramfs: $INITRAMFS    ($(du -h "$INITRAMFS" | cut -f1))"
echo "  DTB:       $DTB          ($(du -h "$DTB" | cut -f1))"
echo "  Output:    $OUTPUT"
echo "  Cmdline:   $CMDLINE"
echo ""

# ---- build via python (handles appended-DTB format that lk2nd needs) ----
export KERNEL INITRAMFS DTB OUTPUT CMDLINE
export KERNEL_ADDR RAMDISK_ADDR TAGS_ADDR PAGE_SIZE VERBOSE

python3 << 'PYEOF'
import struct, os, sys

kernel_path = os.environ["KERNEL"]
ramdisk_path = os.environ["INITRAMFS"]
dtb_path = os.environ["DTB"]
output_path = os.environ["OUTPUT"]
cmdline = os.environ["CMDLINE"].strip()
kernel_addr = int(os.environ["KERNEL_ADDR"], 16)
ramdisk_addr = int(os.environ["RAMDISK_ADDR"], 16)
tags_addr = int(os.environ["TAGS_ADDR"], 16)
page_size = int(os.environ.get("PAGE_SIZE", "2048"))
verbose = os.environ.get("VERBOSE", "0") == "1"

with open(kernel_path, "rb") as f:
    kernel_gz = f.read()
with open(ramdisk_path, "rb") as f:
    ramdisk_data = f.read()
with open(dtb_path, "rb") as f:
    dtb_data = f.read()

# ---- ARM64 appended-DTB format: [gzip_kernel] [DTB] ----
# lk2nd extracts the DTB from the end of the kernel image.
# IMPORTANT: do NOT add padding between gzip and DTB — lk2nd scans for
# DTB magic immediately after the gzip stream and skips padding != 0.
kernel_data = kernel_gz + dtb_data
print(f"  kernel (gzip):           {len(kernel_gz):>10d}")
print(f"  DTB:                     {len(dtb_data):>10d}")
print(f"  kernel+DTB total:        {len(kernel_data):>10d}  ({len(kernel_data)/1024/1024:.1f} MB)")
print(f"  ramdisk:                 {len(ramdisk_data):>10d}  ({len(ramdisk_data)/1024/1024:.1f} MB)")

# ---- pad ----
def pad_to(d, align):
    rem = len(d) % align
    if rem == 0:
        return d
    return d + b'\x00' * (align - rem)

kernel_padded = pad_to(kernel_data, page_size)
ramdisk_padded = pad_to(ramdisk_data, page_size)

header_page = page_size
kernel_start = header_page
ramdisk_start = kernel_start + len(kernel_padded)
total_size = ramdisk_start + len(ramdisk_padded)

# ---- build v0 header ----
hdr = bytearray(page_size)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8,  len(kernel_data))   # kernel_size
struct.pack_into('<I', hdr, 12, kernel_addr)
struct.pack_into('<I', hdr, 16, len(ramdisk_data))   # ramdisk_size
struct.pack_into('<I', hdr, 20, ramdisk_addr)
struct.pack_into('<I', hdr, 24, 0)                    # second_size
struct.pack_into('<I', hdr, 28, 0)                    # second_addr
struct.pack_into('<I', hdr, 32, tags_addr)
struct.pack_into('<I', hdr, 36, page_size)
struct.pack_into('<I', hdr, 40, 0)                    # header_version

cmdline_bytes = cmdline.encode('utf-8')[:511] + b'\x00'
hdr[64:64+len(cmdline_bytes)] = cmdline_bytes
hdr[48:48+6] = b'rescue'

print(f"  cmdline:       {cmdline}")
print(f"  total:         {total_size}  ({total_size/1024/1024:.1f} MB)")

with open(output_path, "wb") as f:
    f.write(bytes(hdr))
    f.write(kernel_padded)
    f.write(ramdisk_padded)

# ---- verify ----
with open(output_path, "rb") as f:
    vdata = f.read()
voff = vdata.find(b'ANDROID!')
vhdr = vdata[voff:]
vk_size = struct.unpack_from('<I', vhdr, 8)[0]
vpage = struct.unpack_from('<I', vhdr, 36)[0]
vk_data = vdata[vpage:vpage+vk_size]
dtb_offsets = []
pos = 0
while True:
    idx = vk_data.find(b'\xd0\x0d\xfe\xed', pos)
    if idx == -1: break
    sz = struct.unpack_from('>I', vk_data, idx+4)[0]
    dtb_offsets.append((idx, sz))
    pos = idx + 1

if dtb_offsets:
    print(f"\n  [OK] DTB appended at kernel offset {dtb_offsets[0][0]}, size {dtb_offsets[0][1]}")
else:
    print(f"\n  [FAIL] No DTB found in kernel section!")
    sys.exit(1)

if vk_data[:2] == b'\x1f\x8b':
    print(f"  [OK] Kernel starts with gzip magic")
else:
    print(f"  [WARN] Kernel doesn't start with gzip magic")

print(f"\n  -> {output_path}")
print(f"  -> Ready:  fastboot boot {output_path}")
PYEOF

echo ""
echo "Done: $(ls -lh "$OUTPUT" | awk '{print $5, $NF}')"

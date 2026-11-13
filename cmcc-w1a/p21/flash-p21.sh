#!/bin/sh
# flash-p21.sh - write out/rootfs.img to /dev/mmcblk0p21 and grow the
# filesystem to fill the whole partition.
#
# DESTROYS the stock Android system on p21.  Run it while the watch is in
# the RECOVERY (p21 is not mounted there, and the recovery has
# e2fsck/resize2fs + ssh):
#
#   ../recovery/boot-recovery.sh        # fastboot boot the recovery
#   ./flash-p21.sh                      # write + resize
#   fastboot boot out/kernel.img        # boot the new p21 rootfs
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="$DIR/out/rootfs.img"
KERNEL="$DIR/out/kernel.img"
DEV="${W1A_DEV:-192.168.2.1}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$DEV"

[ -f "$IMG" ] || { echo "missing $IMG - run build-p21.sh" >&2; exit 1; }

echo "=== checking $DEV"
$SSH 'hostname; grep -q "mmcblk0p21 " /proc/mounts && { echo "p21 is mounted; boot the recovery first"; exit 1; }; command -v resize2fs >/dev/null || { echo "no resize2fs here; use the recovery"; exit 1; }'

echo "=== writing $IMG ($(stat -c%s "$IMG") bytes) to /dev/mmcblk0p21"
cat "$IMG" | $SSH 'dd of=/dev/mmcblk0p21 bs=1M; sync'

echo "=== growing the filesystem to the full p21 partition"
$SSH 'e2fsck -f -y /dev/mmcblk0p21 && resize2fs /dev/mmcblk0p21 && dumpe2fs -h /dev/mmcblk0p21 2>/dev/null | grep -E "Block count|Filesystem state"'

echo
echo "rootfs written and resized.  Boot the matching kernel:"
echo "  fastboot boot $KERNEL"

#!/bin/sh
# boot-recovery.sh - boot recovery/out/w1a-recovery.img on a connected W1A.
#
# This lk2nd build lands in fastboot on every power-on, so recovery is a
# `fastboot boot` (RAM) operation.  Volume Up is the stock EDL combo on
# this device, not a recovery key.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="$DIR/out/w1a-recovery.img"

[ -f "$IMG" ] || { echo "missing $IMG - run build-recovery.sh" >&2; exit 1; }

if ! fastboot devices 2>/dev/null | grep -q fastboot; then
	echo "no fastboot device; power-cycle the watch (it lands in fastboot)" >&2
	exit 1
fi

echo "booting $IMG"
exec fastboot boot "$IMG"

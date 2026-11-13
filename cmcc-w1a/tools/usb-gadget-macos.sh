#!/bin/sh
# Reconfigure the CMCC W1A USB gadget for macOS: CDC-NCM + CDC-ACM.
#
#   usb-gadget-macos.sh [ncm|ecm|rndis] [msc-backing-file]
#
# Defaults to ncm (native on macOS/Linux; RNDIS is NOT supported by
# macOS).  ec is the oldest-host fallback, rndis is for Windows 10 only.
# The optional second argument exports a mass-storage LUN backed by that
# file (never point it at a mounted filesystem).
#
# Unbinding/rebinding the configfs gadget drops the current USB link, so
# run it detached if you are connected over that link, then reconnect at
# 192.168.2.1 over the new interface.
set -e

MODE="${1:-ncm}"
MSC_FILE="$2"
case "$MODE" in
	ncm|ecm|rndis) ;;
	*) echo "usage: $0 [ncm|ecm|rndis] [msc-file]" >&2; exit 2 ;;
esac

G=/sys/kernel/config/usb_gadget/g1
UDC_NAME="$(ls /sys/class/udc 2>/dev/null | head -1)"
[ -n "$UDC_NAME" ] || { echo "no UDC found" >&2; exit 1; }

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# --- tear down whatever is currently bound -------------------------
if [ -e "$G/UDC" ] && [ -n "$(cat "$G/UDC" 2>/dev/null)" ]; then
	echo "" > "$G/UDC"
fi
for l in "$G"/configs/c.1/*; do
	[ -L "$l" ] && rm -f "$l"
done || true
for f in ncm.usb0 ecm.usb0 rndis.usb0 acm.gs0 mass_storage.0; do
	if [ -d "$G/functions/$f" ]; then
		rmdir "$G/functions/$f" 2>/dev/null || true
	fi
done

mkdir -p "$G"
cd "$G"

# --- device descriptor --------------------------------------------
# Composite device: the USB-IF "Miscellaneous/Common/IAD" triple; each
# CDC function's control+data interfaces are paired by an IAD.
echo 0x18d1 > idVendor
echo 0x0a02 > idProduct
echo 0x0200 > bcdUSB
echo 0x0100 > bcdDevice
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

mkdir -p strings/0x409
echo "CMCC" > strings/0x409/manufacturer
echo "W1A" > strings/0x409/product
echo "W1A00000001" > strings/0x409/serialnumber

mkdir -p configs/c.1/strings/0x409
echo "$MODE+acm" > configs/c.1/strings/0x409/configuration
echo 500 > configs/c.1/MaxPower
echo 0x80 > configs/c.1/bmAttributes

# --- functions ----------------------------------------------------
mkdir -p "functions/$MODE.usb0" functions/acm.gs0
# Fixed, locally-administered MACs; must be written before the function
# is linked into a configuration (configfs returns -EBUSY afterwards).
echo 02:11:22:33:44:55 > "functions/$MODE.usb0/dev_addr"
echo 02:11:22:33:44:56 > "functions/$MODE.usb0/host_addr"

[ -L "configs/c.1/$MODE.usb0" ] || ln -s "functions/$MODE.usb0" configs/c.1
[ -L configs/c.1/acm.gs0 ] || ln -s functions/acm.gs0 configs/c.1

if [ -n "$MSC_FILE" ]; then
	mkdir -p functions/mass_storage.0
	echo "$MSC_FILE" > functions/mass_storage.0/lun.0/file
	[ -L configs/c.1/mass_storage.0 ] || ln -s functions/mass_storage.0 configs/c.1
fi

# --- bind + network ----------------------------------------------
echo "$UDC_NAME" > UDC

n=0
while [ ! -e /sys/class/net/usb0 ] && [ $n -lt 15 ]; do
	n=$((n + 1))
	sleep 1
done
if [ -e /sys/class/net/usb0 ]; then
	ip link set usb0 up
	ip addr add 192.168.2.1/24 dev usb0 2>/dev/null || true
	echo "bound: mode=$MODE udc=$UDC_NAME usb0=$(cat /sys/class/net/usb0/address 2>/dev/null)"
else
	echo "ERROR: usb0 never appeared" >&2
	exit 1
fi

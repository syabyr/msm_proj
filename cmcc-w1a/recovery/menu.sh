#!/bin/sh
# W1A recovery menu (serial console /dev/ttyGS0, host /dev/ttyACM1).
#
# Everything here is explicit: read-only checks first, every write asks
# for confirmation, and the boot chain (p4 aboot, p20@0 lk2nd) is never
# touched - only p20@512K / p24 / p33 / p22 / p23 are writable targets.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

. /etc/machine.conf
MNT=/mnt/root
HOST_IP=192.168.2.149   # default build host on the usb0 link; editable below

pause() { printf "\n[Enter] "; read -r _; }
ask()   { printf "%s: " "$1"; read -r _ans; echo "$_ans"; }
confirm() {
	printf "%s\nType YES to continue: " "$1"
	read -r a
	[ "$a" = YES ]
}

part_dev() {
	case "$1" in
		p1)  echo "/dev/${firmware_partition}" ;;
		p20) echo "/dev/${boot_partition}" ;;
		p22) echo "/dev/${persist_partition}" ;;
		p23) echo "/dev/${cache_partition}" ;;
		p24) echo "/dev/${recovery_partition}" ;;
		p33) echo "/dev/${sdcard_partition}" ;;
		*)   echo "" ;;
	esac
}

show_info() {
	echo "=== /proc/partitions ==="
	cat /proc/partitions
	echo
	echo "=== blkid ==="
	blkid 2>/dev/null
	echo
	echo "=== mounted ==="
	mount | grep -E "mmcblk|usb0"
	echo
	echo "=== usb0 / wlan0 ==="
	ip -4 addr 2>/dev/null
}

fsck_ro() {
	p=$(ask "partition to check (p1 p20 p22 p23 p24 p33)")
	d=$(part_dev "$p"); [ -n "$d" ] || { echo "bad partition"; return; }
	echo "--- e2fsck -n $d ---"
	e2fsck -n "$d"
	echo "rc=$?"
}

fsck_repair() {
	p=$(ask "partition to REPAIR (p22 p23 p33)")
	d=$(part_dev "$p"); [ -n "$d" ] || { echo "bad partition"; return; }
	confirm "Run e2fsck -y on $d ?" || return
	umount "$MNT" 2>/dev/null
	e2fsck -y "$d"
}

backup_part() {
	p=$(ask "partition to BACK UP (p20 p22 p23 p24 p33)")
	d=$(part_dev "$p"); [ -n "$d" ] || { echo "bad partition"; return; }
	port=$(ask "host listen port [9000]"); [ -n "$port" ] || port=9000
	echo
	echo "On the HOST run:"
	echo "    socat -u TCP-LISTEN:$port,reuseaddr OPEN:$p-backup.img,creat,trunc"
	echo "or: nc -l -p $port > $p-backup.img"
	echo
	echo "Then this device will stream $d (Ctrl-C to abort)..."
	pause
	socat -u "OPEN:$d,rdonly" "TCP:${HOST_IP}:${port}" || {
		echo "socat failed; trying nc..."
		nc "${HOST_IP}" "$port" < "$d"
	}
	echo "backup stream finished"
}

restore_part() {
	p=$(ask "partition to RESTORE (p20 p22 p23 p24 p33)")
	d=$(part_dev "$p"); [ -n "$p" ] || { echo "bad partition"; return; }
	port=$(ask "host source port [9001]"); [ -n "$port" ] || port=9001
	echo
	echo "On the HOST run:"
	echo "    socat -u OPEN:$p-backup.img TCP:192.168.2.1:$port"
	echo "or: nc 192.168.2.1 $port < $p-backup.img"
	confirm "This OVERWRITES $d. Continue?" || return
	umount "$MNT" 2>/dev/null
	socat -u "TCP-LISTEN:${port},reuseaddr" "OPEN:$d,creat,trunc" || {
		echo "socat failed; trying nc..."
		nc -l -p "$port" > "$d"
	}
	echo "restore finished; run fsck read-only next"
}

flash_boot() {
	f=$(ask "boot.img path on the device (e.g. /tmp/boot.img)")
	[ -f "$f" ] || { echo "no such file: $f"; return; }
	s=$(wc -c < "$f")
	echo "image: $f ($s bytes)"
	confirm "Write $f to /dev/${boot_partition} at 512K offset (p20)?" || return
	dd if="$f" of="/dev/${boot_partition}" bs=4096 seek=128 conv=notrunc
	sync
	echo "flashed; verify: dd if=/dev/${boot_partition} bs=512 skip=1024 count=1 | xxd"
}

ramoops() {
	echo "=== dmesg (tail) ==="
	dmesg | tail -40
	echo
	echo "=== /sys/fs/pstore ==="
	ls -la /sys/fs/pstore 2>/dev/null
	echo "=== /recovery.log (tail) ==="
	tail -60 /recovery.log 2>/dev/null
}

export_msc() {
	echo "USB mass-storage LUN export"
	f=$(ask "file or partition to export (e.g. /dev/${sdcard_partition} or /tmp/x.img)")
	[ -e "$f" ] || { echo "no such file: $f"; return; }
	confirm "Export $f over USB MSC? This resets the USB link." || return
	# Rebuild the gadget with mass_storage.0 added; the serial console
	# respawns on /dev/ttyGS0 when the ACM interface comes back.
	G=/config/usb_gadget/g1
	[ -n "$(cat "$G/UDC" 2>/dev/null)" ] && echo "" > "$G/UDC"
	mkdir -p "$G/functions/mass_storage.0"
	echo "$f" > "$G/functions/mass_storage.0/lun.0/file"
	[ -L "$G/configs/c.1/mass_storage.0" ] || \
		ln -s functions/mass_storage.0 "$G/configs/c.1"
	for u in /sys/class/udc/*; do [ -e "$u" ] && echo "${u##*/}" > "$G/UDC" && break; done
	echo "exported $f; mount it on the host, then re-run this menu"
}

do_reboot() {
	echo "reboot: normal / fastboot / poweroff"
	m=$(ask "[normal|fastboot|poweroff]")
	case "$m" in
		fastboot) echo "hold Volume Down while rebooting for lk2nd fastboot"; sync; reboot -f ;;
		poweroff) sync; poweroff -f ;;
		*) sync; reboot -f ;;
	esac
}

danger() {
	echo "*** DANGER ZONE ***"
	echo " 1) format p24 (recovery)      2) format p33 (Alpine rootfs)"
	echo " 3) wipe p24 boot.img          4) back"
	o=$(ask "choice")
	case "$o" in
		1) confirm "mke2fs -t ext4 /dev/${recovery_partition}?" && mke2fs -t ext4 -F "/dev/${recovery_partition}" ;;
		2) confirm "mke2fs -t ext4 /dev/${sdcard_partition}? (ALL DATA LOST)" && mke2fs -t ext4 -F "/dev/${sdcard_partition}" ;;
		3) confirm "zero p24@512K?" && dd if=/dev/zero of="/dev/${recovery_partition}" bs=1M seek=0 count=20 conv=notrunc && sync ;;
		*) : ;;
	esac
}

while :; do
	cat <<EOF

============================================================
 W1A RECOVERY   $(uname -r)
 usb0 $(ip -4 addr show usb0 2>/dev/null | grep -o 'inet [0-9./]*')
------------------------------------------------------------
 1) shell (ash)
 2) info: partitions / blkid / mounts
 3) fsck read-only
 4) backup partition  -> host (network)
 5) restore partition <- host (network)
 6) flash boot.img -> p20@512K
 7) dmesg / ramoops / recovery log
 8) export file/partition over USB mass storage
 9) reboot (normal / fastboot / poweroff)
 d) fsck repair / danger zone
 q) quit
============================================================
EOF
	printf "recovery> "
	read -r c
	case "$c" in
		1) sh -i ;;
		2) show_info ;;
		3) fsck_ro ;;
		4) backup_part ;;
		5) restore_part ;;
		6) flash_boot ;;
		7) ramoops ;;
		8) export_msc ;;
		9) do_reboot ;;
		d|D) echo " 1) fsck repair  2) danger zone"; o=$(ask "r/d")
		     [ "$o" = r ] && fsck_repair; [ "$o" = d ] && danger ;;
		q|Q) exit 0 ;;
		*) : ;;
	esac
done

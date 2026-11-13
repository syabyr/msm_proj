#!/bin/sh
# W1A Alpine early setup, no-ramdisk (root=/dev/mmcblk0p33) edition.
#
# Everything the old initramfs /init did that neither the kernel (root=
# mount) nor busybox init does for us:
#   1. pseudo filesystems
#   2. USB network + serial gadget (configfs) + usb0 address + udhcpd
#   2b. root shell on the CDC-ACM port (/dev/ttyGS0)
#   3. telnetd rescue channel (busybox-extras, pre-baked)
#   4. sshd (offline ISO apk repo) + WiFi association
#
# Every step logs to the console (visible on screen / ramoops) and to
# /tmp/w1a-init.log so a hung boot shows exactly where it stopped.

LOG=/tmp/w1a-init.log
step() {
    echo "[w1a-init] $*"
    echo "[w1a-init] $*" >> $LOG
}

# --- 1. pseudo filesystems (kernel mounts none of these for us)
mount -t proc proc /proc 2>/dev/null && step "proc ok" || step "proc SKIP"
mount -t sysfs sysfs /sys 2>/dev/null && step "sys ok" || step "sys SKIP"
mount -t devtmpfs devtmpfs /dev 2>/dev/null && step "devtmpfs ok" || step "devtmpfs SKIP"
[ -e /dev/console ] || mknod -m600 /dev/console c 5 1
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs shm /dev/shm 2>/dev/null
mount -t tmpfs run /run 2>/dev/null

hostname -F /etc/hostname 2>/dev/null
mount -a 2>/dev/null

# --- 2. USB network + serial gadget (configfs)
# macOS has no RNDIS host driver (HoRNDIS is dead on Ventura/Apple
# Silicon), but ships native CDC-NCM and CDC-ECM drivers.  Default to
# NCM + ACM so the watch is plug-and-play on macOS/Linux; set
# W1A_USB_MODE=rndis for a Windows-10-only host, or =ecm for the
# oldest hosts.  W1A_USB_MSC=1 exports a mass-storage LUN (backing file
# in W1A_USB_MSC_FILE).
USB_MODE="${W1A_USB_MODE:-ncm}"
case "$USB_MODE" in ncm|ecm|rndis) ;; *) USB_MODE=ncm ;; esac
NET_FN="$USB_MODE.usb0"

(
    mount -t configfs none /sys/kernel/config 2>/dev/null
    cd /sys/kernel/config/usb_gadget || { echo "[gadget] no usb_gadget dir" >> $LOG; exit 1; }
    [ -d g1 ] || mkdir g1
    cd g1
    [ "$(cat UDC 2>/dev/null)" ] && echo "" > UDC 2>/dev/null

    # Composite device: CDC functions must be associated with an IAD, so
    # the device descriptor is the USB-IF "Miscellaneous/Common/IAD"
    # triple (0xEF/0x02/0x01).  macOS matches per-interface and is happy
    # with this; 0x00/0x00/0x00 is the fallback if a host misparses it.
    echo 0x18d1 > idVendor
    echo 0x0a02 > idProduct
    echo 0x0200 > bcdUSB
    echo 0x0100 > bcdDevice
    echo 0xEF > bDeviceClass
    echo 0x02 > bDeviceSubClass
    echo 0x01 > bDeviceProtocol

    [ -d strings/0x409 ] || mkdir strings/0x409
    echo "CMCC" > strings/0x409/manufacturer
    echo "W1A"  > strings/0x409/product
    # A stable non-empty serial makes macOS keep one network service and
    # one /dev/cu.usbmodem* node across reboots.
    echo "W1A00000001" > strings/0x409/serialnumber

    [ -d configs/c.1 ] || mkdir configs/c.1
    [ -d configs/c.1/strings/0x409 ] || mkdir configs/c.1/strings/0x409
    echo "$USB_MODE+acm" > configs/c.1/strings/0x409/configuration
    echo 500 > configs/c.1/MaxPower
    echo 0x80 > configs/c.1/bmAttributes

    [ -d functions/$NET_FN ] || mkdir functions/$NET_FN
    [ -d functions/acm.gs0 ] || mkdir functions/acm.gs0

    # Fixed MACs: without these the kernel's get_ether_addr() falls back
    # to eth_random_addr() and BOTH sides get a NEW random MAC on every
    # boot.  Locally-administered (02:...).  ORDER MATTERS: dev_addr/
    # host_addr are only writable while the function is NOT linked into
    # a configuration (-EBUSY when refcnt != 0; unbinding the UDC is
    # not enough), so write MACs first, THEN link.
    echo "02:11:22:33:44:55" > functions/$NET_FN/dev_addr   2>>$LOG
    echo "02:11:22:33:44:56" > functions/$NET_FN/host_addr  2>>$LOG

    [ -L configs/c.1/$NET_FN ] || ln -s functions/$NET_FN configs/c.1
    [ -L configs/c.1/acm.gs0 ] || ln -s functions/acm.gs0 configs/c.1

    # Optional mass-storage LUN (shows up as a disk on macOS), for file
    # exchange.  Never point this at a mounted filesystem.
    if [ "${W1A_USB_MSC:-0}" = 1 ]; then
        [ -d functions/mass_storage.0 ] || mkdir functions/mass_storage.0
        [ -n "$W1A_USB_MSC_FILE" ] && echo "$W1A_USB_MSC_FILE" > functions/mass_storage.0/lun.0/file
        [ -L configs/c.1/mass_storage.0 ] || ln -s functions/mass_storage.0 configs/c.1
    fi

    for u in /sys/class/udc/*; do
        [ -e "$u" ] || continue
        echo "${u##*/}" > UDC && break
    done
    echo "[gadget] mode=$USB_MODE UDC bound: [$(cat UDC 2>/dev/null)]" >> $LOG
) >> $LOG 2>&1
step "gadget config done (mode=$USB_MODE, UDC: $(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || echo FAILED))"

# usb0 netdev appears at UDC bind; wait then configure
n=0
while [ ! -e /sys/class/net/usb0 ] && [ $n -lt 15 ]; do
    n=$((n+1)); sleep 1
done
if [ -e /sys/class/net/usb0 ]; then
    ip link set usb0 up 2>>$LOG
    ip addr add 192.168.2.1/24 dev usb0 2>>$LOG
    step "usb0 up: $(ip addr show dev usb0 2>/dev/null | grep -o 'inet [0-9./]*')"
else
    step "ERROR: usb0 never appeared (gadget failed)"
fi

# --- 2b. serial console on the CDC-ACM function -------------------
# /dev/ttyGS0 is the gadget's ACM port: macOS exposes it as
# /dev/cu.usbmodem<serialnumber>, Linux as /dev/ttyACM<n>.  Nothing maps
# it to a shell by default (the old initramfs "w1ash" helper did), so
# respawn a detached root shell there.  Debug console only - network SSH
# remains the primary access path.
if [ -c /dev/ttyGS0 ]; then
    (
        while true; do
            setsid sh -c 'exec sh </dev/ttyGS0 >/dev/ttyGS0 2>&1' \
                </dev/null >/dev/null 2>&1
            sleep 1
        done
    ) &
    step "serial console: /dev/ttyGS0 (macOS /dev/cu.usbmodem*, Linux /dev/ttyACM*)"
else
    step "WARN: /dev/ttyGS0 missing (ACM function not created?)"
fi

# --- udhcpd on usb0 (busybox-extras, pre-baked in the rootfs)
if [ -x /usr/sbin/udhcpd ] || [ -x /bin/busybox-extras ]; then
    [ -f /etc/udhcpd.conf ] || cat > /etc/udhcpd.conf <<EOF
interface usb0
start   192.168.2.50
end     192.168.2.150
option subnet 255.255.255.0
option lease 86400
max_leases 16
autoip yes
lease_file /tmp/udhcpd.leases
pidfile /tmp/udhcpd.pid
EOF
    touch /tmp/udhcpd.leases
    /usr/sbin/udhcpd /etc/udhcpd.conf >> $LOG 2>&1 \
        || /bin/busybox-extras udhcpd /etc/udhcpd.conf >> $LOG 2>&1 &
    step "udhcpd started on usb0"
else
    step "WARN: no udhcpd available"
fi

# --- 3. telnetd rescue channel FIRST (busybox-extras, port 2323;
# native rootfs shell, no chroot tricks). Runs even if everything
# below fails - this is the "nothing else works" access path.
if [ -x /bin/busybox-extras ]; then
    /bin/busybox-extras telnetd -l /bin/sh -p 2323 >> $LOG 2>&1 &
    step "telnetd on :2323 (busybox-extras)"
else
    step "WARN: busybox-extras missing, no telnetd"
fi

# --- 3b. audio mixer defaults (speaker + mic, hardware-verified
# 2026-10-21; stock mixer_paths.xml "speaker" path).  Backgrounded:
# waits for the sound card, then opens the SPK path (RX3 MIX1 INP1=RX1,
# SPK DAC on) and the mic path (DEC1=ADC1, CIC1=AMIC).  v3 of this
# script accidentally dropped this section - restored.
(
    n=0
    while [ ! -e /dev/snd/controlC0 ] && [ $n -lt 10 ]; do sleep 1; n=$((n+1)); done
    if [ -e /dev/snd/controlC0 ] && [ -x /usr/bin/sndmix ]; then
        /usr/bin/sndmix /dev/snd/controlC0 "RX3 MIX1 INP1" 3
        /usr/bin/sndmix /dev/snd/controlC0 "SPK DAC Switch" 1
        /usr/bin/sndmix /dev/snd/controlC0 "DEC1 MUX" 1
        /usr/bin/sndmix /dev/snd/controlC0 "CIC1 MUX" 0
        echo "[audio] mixer defaults applied" >> $LOG
    else
        echo "[audio] WARN: no controlC0 or sndmix" >> $LOG
    fi
) &

# --- 3c. modem (MSS) for GPS: stage firmware from the modem partition
# (vfat p1, image/ dir, ~35MB - too big to bake into the rootfs) and
# rebind the remoteproc.  The remoteproc probed at ~1s before any
# filesystem was ready, exactly like WCNSS.  After the modem is up the
# hexagon smd-edge brings up IPCRTR for qrtr; GPS itself is then
# libqmi/gpsd in userspace (qmicli --loc-*).
(
    mkdir -p /mnt/modemfw /lib/firmware
    if mount -t vfat -o ro /dev/mmcblk0p1 /mnt/modemfw 2>>/tmp/modem.log; then
        # COPY, not symlink: the remoteproc re-binds later and may
        # request_firmware again (suspend/resume, manual rebind); a
        # symlink would dangle after the umount below.  35MB into the
        # root fs is fine on the 1.9GB partition.
        for f in /mnt/modemfw/image/modem.* /mnt/modemfw/image/mba.mbn; do
            [ -e "$f" ] && cp -f "$f" /lib/firmware/ 2>>/tmp/modem.log
        done
        echo "[modem] firmware staged: $(ls /lib/firmware/modem.mdt /lib/firmware/mba.mbn 2>/dev/null | wc -l) files" >> /tmp/modem.log
        umount /mnt/modemfw 2>>/tmp/modem.log
    else
        echo "[modem] WARN: p1 vfat mount failed" >> /tmp/modem.log
    fi

    # find the mpss remoteproc (index varies: wcnss may be remoteproc0)
    MPSS=""
    for rp in /sys/class/remoteproc/remoteproc*; do
        [ "$(cat $rp/name 2>/dev/null)" = "4080000.remoteproc" ] || \
        [ "$(cat $rp/name 2>/dev/null)" = "remoteproc@4080000" ] || continue
        MPSS=$rp
        break
    done
    if [ -n "$MPSS" ]; then
        echo "[modem] mpss at $MPSS, state: $(cat $MPSS/state)" >> /tmp/modem.log
        st=$(cat $MPSS/state 2>/dev/null)
        if [ "$st" != "running" ]; then
            # q6v5 sets rproc->auto_boot = false: probing the driver
            # (even a full unbind/bind) never boots the modem.  The
            # userspace trigger is the remoteproc sysfs "state" file.
            # Firmware is already copied into /lib/firmware above.
            echo start > $MPSS/state 2>>/tmp/modem.log
            # the mba+mpss load + boot takes a few seconds
            n=0
            while [ "$(cat $MPSS/state 2>/dev/null)" != "running" ] && [ $n -lt 20 ]; do
                n=$((n+1)); sleep 1
            done
        fi
        echo "[modem] after: state=$(cat $MPSS/state 2>/dev/null)" >> /tmp/modem.log
    else
        echo "[modem] WARN: mpss remoteproc not found" >> /tmp/modem.log
    fi
) &

# --- 4a. sshd from the local (offline) ISO apk repo
if [ ! -x /usr/sbin/sshd ]; then
    step "installing openssh-server (offline)"
    apk add --repository /srv/apks-iso/armv7 openssh-server >> /tmp/apk.log 2>&1 \
        && step "openssh installed" || step "ERROR: openssh install failed"
fi
if [ -x /usr/sbin/sshd ]; then
    [ -e /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >> /tmp/apk.log 2>&1
    mkdir -p /var/empty /run/sshd 2>/dev/null
    /usr/sbin/sshd >> /tmp/apk.log 2>&1 && step "sshd started (:22)" || step "ERROR: sshd failed"
else
    step "WARN: sshd not available"
fi

# --- 4b. WiFi (backgrounded: association/DHCP can take 30s+ and
# must NOT block the rest of sysinit)
(
    # A fresh rootfs has neither the WCNSS firmware nor its NV: stage
    # them from p1 (image/) and p22 (persist) BEFORE the rebind, or
    # request_firmware(wcnss.mdt) fails and wlan0 never appears.
    mkdir -p /lib/firmware/wlan/prima
    if [ ! -e /lib/firmware/wcnss.mdt ]; then
        mkdir -p /mnt/wcnssfw
        if mount -t vfat -o ro /dev/mmcblk0p1 /mnt/wcnssfw 2>>/tmp/wifi.log; then
            cp -f /mnt/wcnssfw/image/wcnss.* /lib/firmware/ 2>>/tmp/wifi.log
            umount /mnt/wcnssfw 2>>/tmp/wifi.log
        else
            echo "[wifi] WARN: p1 mount failed" >> /tmp/wifi.log
        fi
    fi
    if grep -q mmcblk0p22 /proc/mounts; then
        nvsrc=$(awk '$1=="/dev/mmcblk0p22"{print $2; exit}' /proc/mounts)
    else
        mkdir -p /mnt/wcnssp
        mount -t ext4 -o ro /dev/mmcblk0p22 /mnt/wcnssp 2>>/tmp/wifi.log && nvsrc=/mnt/wcnssp
    fi
    if [ -n "$nvsrc" ] && [ ! -e /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin ]; then
        cp -f "$nvsrc"/WCNSS_qcom_wlan_nv.bin /lib/firmware/wlan/prima/ 2>>/tmp/wifi.log
        cp -f "$nvsrc"/WCNSS_wlan_dictionary.dat /lib/firmware/wlan/prima/ 2>/dev/null
    fi
    [ "$nvsrc" = /mnt/wcnssp ] && umount /mnt/wcnssp 2>/dev/null
    echo "[wifi] fw=$(ls /lib/firmware/wcnss.mdt 2>/dev/null && echo ok || echo MISSING) nv=$(ls /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin 2>/dev/null && echo ok || echo MISSING)" >> /tmp/wifi.log

    # WCNSS rebind (from the initramfs /init): the remoteproc probed at
    # ~1s, BEFORE the root filesystem was mounted, so its initial
    # request_firmware(wcnss.mdt) failed and it sits offline.  The
    # firmware IS on the root fs now (/lib/firmware) - force a reprobe.
    if [ -e /sys/bus/platform/drivers/qcom-wcnss-pil/a204000.remoteproc ]; then
        st=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)
        echo "[wifi] wcnss state: $st - rebinding" >> /tmp/wifi.log
        echo a204000.remoteproc > /sys/bus/platform/drivers/qcom-wcnss-pil/unbind 2>>/tmp/wifi.log
        sleep 1
        echo a204000.remoteproc > /sys/bus/platform/drivers/qcom-wcnss-pil/bind 2>>/tmp/wifi.log
        sleep 3
        echo "[wifi] after rebind: $(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" >> /tmp/wifi.log
    fi

    # wcn36xx registers wlan0 when the remoteproc is up; wait for it
    n=0
    while [ ! -e /sys/class/net/wlan0 ] && [ $n -lt 15 ]; do
        n=$((n+1)); sleep 1
    done
    echo "[wifi] wlan0: $([ -e /sys/class/net/wlan0 ] && echo exists || echo MISSING)" >> /tmp/wifi.log

    if [ -e /sys/class/net/wlan0 ]; then
        apk add --repository /srv/apks-iso/armv7 wpa_supplicant iw >> /tmp/apk.log 2>&1
        ip link set wlan0 up 2>>/tmp/wifi.log
        wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/w1a.conf >> /tmp/wifi.log 2>&1
        n=0
        while [ $n -lt 30 ]; do
            udhcpc -i wlan0 -n -q -t 5 -T 2 >> /tmp/wifi.log 2>&1 && break
            n=$((n+1)); sleep 1
        done
        # Some APs (e.g. the N60Pro here) do not send a DHCP router
        # option, so udhcpc leaves no default route and apk/DNS to the
        # internet fail.  Fall back to the subnet's .1.
        if ! ip route 2>/dev/null | grep -q '^default'; then
            gw=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')
            if [ -n "$gw" ]; then
                ip route add default via "$gw" dev wlan0 2>>/tmp/wifi.log
                echo "[wifi] no DHCP router, default via $gw" >> /tmp/wifi.log
            fi
        fi
        echo "[wifi] wlan0: $(ip -4 addr show wlan0 2>/dev/null | grep inet)" >> /tmp/wifi.log
    else
        echo "[wifi] ERROR: wlan0 never appeared after rebind" >> /tmp/wifi.log
    fi
) &

# --- 4c. time sync: no battery-backed RTC (the clock starts at 1970)
# and no service manager; sync once the link is up, persist to the RTC,
# then re-sync every 6h.
(
    i=0
    while [ $i -lt 30 ]; do
        if timeout 20 ntpd -q -n -p ntp.aliyun.com -p ntp1.aliyun.com \
                 -p cn.pool.ntp.org 2>>/tmp/time.log; then
            echo "[time] synced: $(date -u)" >> /tmp/time.log
            hwclock -w 2>>/tmp/time.log
            break
        fi
        i=$((i+1)); sleep 10
    done
    while :; do
        sleep 21600
        timeout 20 ntpd -q -n -p ntp.aliyun.com -p ntp1.aliyun.com 2>>/tmp/time.log \
            && hwclock -w 2>>/tmp/time.log
        echo "[time] resync: $(date -u)" >> /tmp/time.log
    done
) &

echo ""
echo "W1A Alpine Linux $(cat /etc/alpine-release 2>/dev/null)"
echo "access: telnet port 2323 / ssh root@192.168.2.1 (usb $USB_MODE)"
echo "apk repo: /srv/apks-iso/armv7"
echo ""

# p21: the DRM fbdev starts blanked (FB_BLANK_POWERDOWN).  With
# w1a.no_dsi_pa the command-mode frame stream is healthy, so unblank the
# panel (background write so a wedged commit can never block init).
[ -e /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null &

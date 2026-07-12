# Auto Rotation Fix for Xiaomi Redmi 7 (onclite) - postmarketOS 26.06

## Problem

Screen auto rotation not working on Redmi 7 running postmarketOS 26.06 (kernel 7.0.9-msm8953).
No accelerometer detected in Phosh.

## Root Cause

Two missing pieces:

1. **Missing i2c-gpio sensor bus in DTB** — The ST LIS2HH12 accelerometer and STK33502 light/proximity
   sensor share an i2c bus implemented as GPIO bit-banging (GPIO 14=SDA, GPIO 15=SCL). This bus
   was not described in the device tree.

2. **Missing kernel modules** — The ST accelerometer driver (st_accel_i2c) and its dependencies
   (st_sensors, st_sensors_i2c, st_accel) were not included in the postmarketOS kernel build.
   Additionally, the kernel uses CFI (Control Flow Integrity) which requires modules to be built
   with a matching clang version.

## Solution Overview

- **DTB modification**: Add `i2c-sensors` node with GPIO bit-banging bus, LIS2HH12 accelerometer
  at address 0x1d, and STK3310 light sensor at 0x47
- **Kernel modules**: Cross-compile st_sensors.ko, st_sensors_i2c.ko, st_accel.ko, st_accel_i2c.ko
  with matching CFI type hashes using Fedora clang 22.1.8

## Hardware Details

| Component       | Sensor         | I2C Address | GPIO (interrupt) | Supply   |
|-----------------|----------------|-------------|-------------------|----------|
| Accelerometer   | ST LIS2HH12    | 0x1d        | GPIO 42 (rising)  | AVDD 2.8V, VDDIO 1.8V |
| Light/Proximity | Sensortek STK33502 (STK3310 driver) | 0x47 | GPIO 43 (rising) | AVDD 2.8V, VDDIO 1.8V |

I2C bus: GPIO 14 = SDA, GPIO 15 = SCL (bit-banged via i2c-gpio driver)

### Mount Matrix

```
-1,  0,  0
 0,  1,  0
 0,  0,  1
```

The accelerometer X axis is inverted relative to the device screen.

## Files in This Directory

```
autorotation/
├── README.md                                  ← This document
├── sdm632-xiaomi-onclite-sensors-v6.dtb       ← Final DTB with sensor bus
├── sdm632-xiaomi-onclite-sensors-v6.dts       ← Decompiled DTS source
└── modules/
    ├── st_sensors.ko                           ← ST sensors core framework
    ├── st_sensors_i2c.ko                       ← ST sensors I2C transport
    ├── st_accel.ko                             ← ST accelerometer core
    └── st_accel_i2c.ko                         ← ST accelerometer I2C driver (LIS2HH12)
```

## DTB Changes

### Original DTB (PMS 26.06 stock)
No i2c-sensors node — accelerometer and light sensor buses not described.

### Modified DTB
Added `i2c-sensors` node as a child of the root `/` node:

```dts
i2c-sensors {
    compatible = "i2c-gpio";
    sda-gpios = <0x39 0x0e 0x06>;   /* GPIO 14, ACTIVE_HIGH|OPEN_DRAIN */
    scl-gpios = <0x39 0x0f 0x06>;   /* GPIO 15, ACTIVE_HIGH|OPEN_DRAIN */
    i2c-gpio,delay-us = <0x02>;
    #address-cells = <0x01>;
    #size-cells = <0x00>;

    accelerometer@1d {
        compatible = "st,lis2hh12";
        reg = <0x1d>;
        interrupt-parent = <0x39>;   /* tlmm */
        interrupts = <0x2a 0x01>;    /* GPIO 42, IRQ_TYPE_EDGE_RISING */
        vdd-supply = <0x8c>;         /* pm8953_l10 (AVDD 2.8V) */
        vddio-supply = <0x46>;       /* pm8953_l6 (VDDIO 1.8V) */
        mount-matrix = "-1", "0", "0",
                       "0",  "1", "0",
                       "0",  "0", "1";
    };

    light-sensor@47 {
        compatible = "sensortek,stk3310";
        reg = <0x47>;
        interrupt-parent = <0x39>;
        interrupts = <0x2b 0x01>;    /* GPIO 43, IRQ_TYPE_EDGE_RISING */
        vdd-supply = <0x8c>;
        vddio-supply = <0x46>;
    };
};
```

**Phandle references** (numeric values in DTS compiled form):
- `0x39` = tlmm (GPIO controller)
- `0x8c` = pm8953_l10 (regulator L10, 2.8V AVDD)
- `0x46` = pm8953_l6 (regulator L6, 1.8V VDDIO)
- GPIO flags `0x06` = `GPIO_ACTIVE_HIGH | GPIO_OPEN_DRAIN`

## Kernel Module Build

### Build Environment

The device kernel (7.0.9-msm8953) was built with **Alpine clang 22.1.3** and has **CFI enabled**:
```
CONFIG_CFI=y
CONFIG_CFI_ICALL_NORMALIZE_INTEGERS=y
```

CFI (Control Flow Integrity) embeds type hashes before function entries. The kernel validates
these hashes on indirect calls. Modules MUST be built with a clang version that produces
matching CFI type hashes.

### Why Fedora clang?

Alpine clang 22.1.8 uses musl libc, making cross-integration with the glibc-based kernel build
system difficult (host tools like `conf`, `fixdep`, `modpost` wouldn't run). Fedora's clang
22.1.8 is glibc-based, produces the correct CFI hash (`0x6fbb3035` for `int (*)(void)`),
and fully integrates with the kernel build system.

### Build Commands

```bash
# In kernel source directory:
make LLVM=1 ARCH=arm64 olddefconfig
make LLVM=1 ARCH=arm64 modules_prepare
make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/common/st_sensors
make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/accel
```

Or using Docker with Fedora:
```bash
docker run --rm --network host \
  -v $(pwd):/build -w /build \
  fedora:latest sh -c "
    dnf install -y clang lld llvm make flex bison bc elfutils-libelf-devel openssl-devel
    make LLVM=1 ARCH=arm64 olddefconfig
    make LLVM=1 ARCH=arm64 modules_prepare
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/common/st_sensors
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/accel
  "
```

### Kernel Config Additions

The device's `.config` needed these additions before building:
```
CONFIG_IIO_ST_ACCEL_3AXIS=m
CONFIG_IIO_ST_ACCEL_I2C_3AXIS=m
```

### setlocalversion Fix

The kernel source tag `v7.0.9-r0` must be an **annotated** tag (not lightweight) to prevent
`setlocalversion` from appending `+` to the vermagic:
```bash
git tag -a v7.0.9-r0 -m "v7.0.9-r0" -f
```

## Deployment

### 1. Deploy DTB

```bash
# On device (via SSH):
sudo cp sdm632-xiaomi-onclite-sensors-v6.dtb /boot/dtbs/qcom/
# Update extlinux.conf or boot config to use the new DTB
sudo reboot
```

### 2. Install Kernel Modules

```bash
# Copy modules to device:
scp modules/st_*.ko mybays@172.16.42.1:/tmp/

# On device:
sudo cp /tmp/st_*.ko /lib/modules/7.0.9-msm8953/extra/
sudo depmod -a
```

### 3. Configure Auto-Loading at Boot

```bash
sudo cat > /etc/modules-load.d/st-accel.conf << 'EOF'
# ST LIS2HH12 accelerometer modules
st_sensors
st_sensors_i2c
st_accel
st_accel_i2c
EOF
```

### 4. Restart iio-sensor-proxy

After reboot, the modules load automatically. If the accelerometer isn't detected by
iio-sensor-proxy (it may start before modules finish loading):

```bash
sudo systemctl restart iio-sensor-proxy
```

## Verification

### Check Modules Loaded
```bash
lsmod | grep st_
# Expected output:
# st_accel_i2c           16384  0
# st_accel               20480  2 st_accel_i2c
# st_sensors_i2c         12288  1 st_accel_i2c
# st_sensors             28672  3 st_accel_i2c,st_accel
```

### Check Accelerometer Detected
```bash
cat /sys/bus/iio/devices/iio:device0/name
# Expected: lis2hh12
```

### Check Sensor Data
```bash
sudo cat /sys/bus/iio/devices/iio:device0/in_accel_x_raw
sudo cat /sys/bus/iio/devices/iio:device0/mount_matrix
# Expected: -1, 0, 0; 0, 1, 0; 0, 0, 1
```

### Check DBus
```bash
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
  net.hadess.SensorProxy HasAccelerometer
# Expected: b true

busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
  net.hadess.SensorProxy AccelerometerOrientation
# Expected: s "normal" / "right-up" / "bottom-up" / "left-up" (changes with orientation)
```

## Troubleshooting

### CFI failure in dmesg
```
CFI failure at do_one_initcall+0xdc/0x3e0 (target: init_module+0x0/0xfd0 [st_accel_i2c])
```
The modules were built with an incompatible clang version. Rebuild with clang 22.1.x from
Fedora or Alpine (glibc-based preferred for build system compatibility).

### No IIO device for accelerometer
Check that the DTB has been deployed and the device rebooted:
```bash
dmesg | grep i2c-sensors
# Expected: i2c-gpio i2c-sensors: using lines 526 (SDA) and 527 (SCL)

dmesg | grep lis2hh12
# Expected: st-accel-i2c 0-001d: interrupts on the rising edge
```

### iio-sensor-proxy doesn't see accelerometer
Restart the service after modules are loaded:
```bash
sudo systemctl restart iio-sensor-proxy
```

For debugging:
```bash
sudo systemctl stop iio-sensor-proxy
sudo IIO_SENSOR_PROXY_DEBUG=1 /usr/libexec/iio-sensor-proxy -v
```

### Resource busy when reading raw values
This is normal — it means the buffer is enabled by iio-sensor-proxy and data is streaming.

## Technical Notes

- **CFI type hash `0x6fbb3035`**: This is the expected hash for `int (*)(void)` function pointer
  type when `CONFIG_CFI_ICALL_NORMALIZE_INTEGERS=y`. Both Alpine clang 22.1.3 and Fedora
  clang 22.1.8 produce this same hash.
- **Mount matrix**: The `-1` on X axis inverts the accelerometer's X reading to match the
  device's screen coordinate system.
- **i2c-gpio driver**: Built into the kernel (not a module), provides the i2c-sensors bus
  automatically when described in DTB.
- **Module dependencies**: st_sensors → st_sensors_i2c → st_accel → st_accel_i2c (load order
  is handled automatically by modprobe/depmod).

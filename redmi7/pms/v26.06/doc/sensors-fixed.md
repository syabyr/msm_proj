# PMS 26.06 — Sensors/Battery/Charger/Speaker/USB 完整修复

Xiaomi Redmi 7 (onclite), kernel 7.0.9-msm8953, postmarketOS 26.06.

## 验证结果 (2026-07-12)

| 组件 | DTB | 驱动 | 设备状态 |
|------|-----|------|---------|
| 加速度计 LIS2HH12 | i2c-sensors bus | st_accel_i2c.ko | **工作** — iio:device0=lis2hh12 |
| 光线/接近 STK33502 | i2c-sensors bus | stk3310 (内置) | **工作** — iio:device1=stk3310 |
| PMI632 充电器 | charger@1000 | qcom-smbchg (内置) | **工作** — /sys/class/power_supply/qcom-smbchg-usb |
| PMI632 电量计 | fuel-gauge@4800 | pmi632-qg-fg (无驱动) | **不工作** — 已知 PMI632 寄存器不兼容 |
| USB Host 模式 | dr_mode=host | dwc3 (内置) | **工作** — xHCI Host Controller + 2 root hubs |
| USB VBUS 5V | usb-vbus-regulator@1100 | pmi632-vbus-reg (内置) | **已启用** (status=okay) |
| 扬声器放大器 AW87329/AW8738 | speaker_amp | snd-soc-aw8738.ko | **工作** — 模块加载, GPIO 139 正确, 扬声器出声 (含 mixer 配置) |
| 电池参数 | battery node | simple-battery (内置) | **已配置** — 4000mAh |

### AW87329/AW8738 扬声器 — 完整修复 (2026-07-12)

#### 关键发现

从 Android kernel source (`msm8953-audio.dtsi`) 确认:
- **芯片**: 实际是 AW873**29** (I2C 接口, addr 0x58), 不是 AW8738
- **GPIO**: 使用 **GPIO 139** 作为 reset/mode pin (不是之前用的 GPIO 96)
- **AW8738 驱动兼容**: mainline 的 `aw8738.c` 通过 GPIO 脉冲模式控制功放, 与 AW87329 的 GPIO 接口兼容

Android DTS 中的原始配置:
```dts
i2c@7af5000 {
    aw87329@58 {
        compatible = "awinic,aw87329_pa";
        reg = <0x58>;
        reset-gpio = <&tlmm 139 0>;   // GPIO 139
    };
};
```

#### 完整 DAPM 音频通路

```
MultiMedia3 Playback (hw:0,2)
    ↓ (PRI_MI2S_RX Audio Mixer)
PRI_MI2S_RX → Primary MI2S Playback → AIF1 Playback → I2S RX3
    ↓
PDM_RX3 (WCD analog codec)
    ↓ (SPK DAC Switch 必须 On)
SPK DAC → SPK PA → SPK_OUT (WCD)
    ↓
Speaker Amp IN → Speaker Amp DRV → Speaker Amp OUT (AW8738 驱动)
    ↓
Speaker (声卡 widget)
    ↓
GPIO 139 = HIGH (AW8738 发送 mode=5 脉冲 → 功放使能, 最大增益)
```

**关键**: 扬声器使用 `MultiMedia3` (RX3/PDM_RX3), 不是 `MultiMedia1` (RX1 — 耳机通路)。

#### 播放音频需要启用的 mixer 控制

```bash
# 1. 数字 codec: I2S RX3 → RX3 MIX1 (PCM 数据进入 PDM_RX3 通道)
amixer cset numid=59 "RX3"   # RX3 MIX1 INP1 = RX3

# 2. DSP 路由: MultiMedia3 → Primary MI2S RX
amixer cset numid=152 on     # PRI_MI2S_RX Audio Mixer MultiMedia3

# 3. 模拟 codec: PDM_RX3 → SPK DAC
amixer cset numid=73 on      # SPK DAC Switch

# 4. 功放使能
amixer cset numid=52 on      # Speaker Switch

# 5. 通过 hw:0,2 播放 (注意是 device 2, 不是 device 0)
aplay -D hw:0,2 /path/to/audio.wav
```

#### 调试 sysfs 节点

```
/sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker Amp IN
/sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker Amp DRV
/sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker Amp OUT
/sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK DAC
/sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK PA
/sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK_OUT
/sys/kernel/debug/asoc/xiaomi-onclite/dapm/Speaker
/sys/kernel/debug/gpio  # 搜索 gpio139 — 播放时为 out high, 空闲时为 out low
```

### 充电器状态 (未接 USB)

```
/sys/class/power_supply/qcom-smbchg-usb/uevent:
  POWER_SUPPLY_NAME=qcom-smbchg-usb
  POWER_SUPPLY_TYPE=USB
  POWER_SUPPLY_STATUS=Discharging
  POWER_SUPPLY_CHARGE_TYPE=Fast
  POWER_SUPPLY_HEALTH=Good
  POWER_SUPPLY_CONSTANT_CHARGE_CURRENT=2200000
  POWER_SUPPLY_CONSTANT_CHARGE_CURRENT_MAX=1000000
  POWER_SUPPLY_INPUT_CURRENT_LIMIT=100000
  POWER_SUPPLY_USB_TYPE=[Unknown] SDP DCP CDP   ← USB 类型自动检测已就绪
```

插入 USB 充电器后，STATUS 会变为 `Charging`，ONLINE=1，PRESENT=1。

### USB Host 模式

```
Bus 001 Device 001: ID 1d6b:0002 Linux 7.0.9-msm8953 xhci-hcd xHCI Host Controller
Bus 002 Device 001: ID 1d6b:0003 Linux 7.0.9-msm8953 xhci-hcd xHCI Host Controller
```

xHCI 控制器正常工作，可直接插入 USB 设备 (U盘、键盘、鼠标等)。

### 已知限制

1. **USB Host 模式下无 USB gadget 网络** — `dr_mode=host` 禁用了 peripheral 模式，USB 网络共享 (172.16.42.1) 不可用。需要通过 WiFi (192.168.1.185) 连接设备。

2. **电量计不工作** — PMI632 的燃料计与 PMI8994/PMI8996 寄存器布局不同，mainline 内核驱动 (`pmi8994_fg`) 不兼容。只能通过充电器状态判断充放电，无法读取电池百分比。

3. **扬声器需要手动 mixer 配置** — 当前系统不会自动配置 MultiMedia3 路由。每次重启后需执行:
```bash
amixer cset numid=59 "RX3"    # 数字 codec: I2S RX3 → RX3 MIX1
amixer cset numid=152 on      # PRI_MI2S_RX Audio Mixer MultiMedia3
amixer cset numid=73 on       # SPK DAC Switch
amixer cset numid=52 on       # Speaker Switch
```
或通过 ALSA UCM profile / PulseAudio 配置自动启用。扬声器播放设备是 `hw:0,2` (不是 `hw:0,0`)。

## 文件

```
msm_proj/redmi7/pms/v26.06/
├── README.md                                    ← 总览和部署说明
├── dts/
│   ├── sdm632-xiaomi-onclite-v3-sensors-fixed.dts   ← DTS 源码
│   └── sdm632-xiaomi-onclite-v3-sensors-fixed.dtb   ← 编译后 DTB
├── modules/
│   ├── st_sensors.ko                             ← ST 传感器核心
│   ├── st_sensors_i2c.ko                         ← ST 传感器 I2C
│   ├── st_accel.ko                               ← ST 加速度计核心
│   ├── st_accel_i2c.ko                           ← LIS2HH12 驱动
│   └── snd-soc-aw8738.ko                        ← AW8738 扬声器功放
├── linux-7.0.9/                                  ← 内核源码
└── doc/
    ├── auto_rotation.md                          ← 自动旋转修复
    ├── usb-autoswitch.md                         ← USB Host/Device 切换分析
    └── sensors-fixed.md                          ← 本文档
```

## DTB 修改详情 (对比 PMS 26.06 stock)

### 已有 (PMS 26.06 已支持，本期确认)
- `i2c-sensors` — GPIO bit-bang I2C 总线 (GPIO 14=SDA, GPIO 15=SCL)
  - `accelerometer@1d` — ST LIS2HH12 (已验证工作)
  - `light-sensor@47` — Sensortek STK3310 (已验证工作)

### 新增 (从 PMS 25.12 移植，本期验证)

**1. PMI632 SPMI pmic@2:**
- `usb-vbus-regulator@1100`: status disabled → okay, 添加 regulator 参数
- `charger@1000`: 新增节点 (qcom,pmi8996-smbchg), 带 31 个中断

**2. PMI632 SPMI pmic@2:**
- `fuel-gauge@4800`: 新增节点 (qcom,pmi632-qg-fg), 已知无驱动

**3. USB:**
- 删除: `usb-role-switch`, `role-switch-default-mode`, `ports` block
- 添加: `dr_mode = "host"`

**4. 根节点:**
- `speaker_amp: audio-amplifier` — AW8738 功放 (GPIO 139, mode=5) — **GPIO 已修正 (2026-07-12)**
- `battery` — simple-battery 4000mAh

**5. sound-card@c051000:**
- 添加: `widgets = "Speaker", "Speaker"`
- 添加: `pin-switches = "Speaker"`
- 添加: `aux-devs = <&speaker_amp>`
- 追加 audio-routing: Speaker ↔ Speaker Amp, Speaker Amp ↔ SPK_OUT

## 部署

### DTB

```bash
# 复制到设备
scp dts/sdm632-xiaomi-onclite-v3-sensors-fixed.dtb mybays@192.168.1.185:/tmp/

# 在设备上 — 需要覆盖两个位置
sudo cp /tmp/sdm632-xiaomi-onclite-v3-sensors-fixed.dtb /boot/sdm632-xiaomi-onclite.dtb
sudo cp /tmp/sdm632-xiaomi-onclite-v3-sensors-fixed.dtb /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb
sudo reboot
```

注意: extlinux 使用 `fdtdir /` 递归扫描，`/boot/sdm632-xiaomi-onclite.dtb` 会优先匹配。
必须同时覆盖两个位置。

### 内核模块

```bash
# 复制模块
scp modules/*.ko mybays@192.168.1.185:/tmp/

# 在设备上
sudo cp /tmp/st_*.ko /lib/modules/7.0.9-msm8953/extra/
sudo cp /tmp/snd-soc-aw8738.ko /lib/modules/7.0.9-msm8953/extra/
sudo depmod -a
```

### 自动加载

```bash
# ST 加速度计
echo 'st_sensors
st_sensors_i2c
st_accel
st_accel_i2c' | sudo tee /etc/modules-load.d/st-accel.conf

# AW8738 扬声器
echo 'snd-soc-aw8738' | sudo tee /etc/modules-load.d/aw8738.conf
```

### 重启后验证

```bash
# 传感器
cat /sys/bus/iio/devices/iio:device0/name   # lis2hh12
cat /sys/bus/iio/devices/iio:device1/name   # stk3310

# 充电器
cat /sys/class/power_supply/qcom-smbchg-usb/uevent

# USB Host
lsusb   # 应显示 xHCI Host Controller

# 扬声器 — 启用 mixer 控制
amixer cset numid=152 on   # PRI_MI2S_RX Audio Mixer MultiMedia3
amixer cset numid=73 on    # SPK DAC Switch
amixer cset numid=52 on    # Speaker Switch

# 扬声器测试 — 使用 hw:0,2 (MultiMedia3), 不是 hw:0,0
pasuspender -- speaker-test -t sine -f 440 -l 3 -D hw:0,2

# 扬声器 DAPM 验证
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker\ Amp\ DRV | head -1  # 播放时应显示 On
sudo cat /sys/kernel/debug/gpio | grep gpio139  # 播放时应显示 out high

# 旋转
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer
```

## 编译说明

DTB: `dtc -I dts -O dtb -o output.dtb input.dts`

内核模块需要 Fedora Docker + clang 22.1.8 (匹配内核 CFI 类型哈希):

```bash
docker run --rm --network host \
  -v $(pwd)/linux-7.0.9:/build -w /build \
  fedora:latest sh -c "
    dnf install -y clang lld llvm make flex bison bc elfutils-libelf-devel openssl-devel
    make LLVM=1 ARCH=arm64 olddefconfig
    make LLVM=1 ARCH=arm64 modules_prepare
    # ST 传感器
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/common/st_sensors
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=drivers/iio/accel
    # AW8738
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=sound/soc/codecs modules
  "
```

内核已配置:
- `CONFIG_CHARGER_QCOM_SMBCHG=y` — 充电器 (内置)
- `CONFIG_BATTERY_PMI8994_FG=y` — 电量计 (内置，与 PMI632 不兼容)
- `CONFIG_SND_SOC_AW8738=m` — 扬声器功放 (模块)
- `CONFIG_IIO_ST_ACCEL_3AXIS=m` — ST 加速度计 (模块)

# Xiaomi Redmi 7 (onclite) @ 192.168.1.159 — 传感器诊断文档

## 设备信息

| 项目 | 值 |
|------|-----|
| 设备型号 | Xiaomi Redmi 7 (onclite) |
| SoC | Qualcomm Snapdragon 632 (SDM632) |
| OS | postmarketOS |
| 内核 | 6.17.7-msm8953 |

## 硬件传感器清单

通过 I2C 扫描和寄存器探测确认的实际硬件：

| 传感器 | 硬件芯片 | I2C 地址 | 当前状态 |
|--------|---------|:-------:|----------|
| 加速度计 (Accelerometer) | **ST LIS2HH12** | 0x1D | **需内核重编译** — DT 已修复，缺 ST accel 驱动 |
| 光线/接近传感器 | **STK33502 (类 STK3310)** | 0x47 | **部分工作** — STK3310 驱动已加载，IIO 数据可读 |
| 磁力计/电子罗盘 | ❌ **未检测到** | — | I2C 总线上无磁力计芯片 |
| 陀螺仪 (Gyroscope) | ❌ | — | 此设备无陀螺仪 |
| 指纹传感器 | Goodix/FPC | — | 未检查 |
| 红外发射器 (IR Blaster) | ✅ | — | 未检查 |
| 温度传感器 (Thermal) | PMIC 内置 | — | **工作** |
| PMIC ADC (电压测量) | PM8941 内置 | — | **工作** |

## 根因分析

**原始 DTB 完全缺少 i2c-gpio 传感器总线节点。**

Redmi 7 的传感器通过 **i2c-gpio (bit-banged I2C, GPIO 14=SDA, GPIO 15=SCL)** 连接，
而非 SoC 原生 BLSP I2C 控制器。原 DTB 中无此总线定义，因此所有传感器都无法探测。

现已确认：
- **LIS2HH12 加速度计** (WHO_AM_I = 0x41) at I2C 0x1D — 需要 `CONFIG_IIO_ST_ACCEL_3AXIS` 驱动模块
- **STK33502 光感/接近** (PART_ID = 0x52) at I2C 0x47 — 当前 STK3310 驱动可基础工作
- **无磁力计** — Redmi 7 可能未配备电子罗盘

## 诊断过程

### 1. 输入设备

`/proc/bus/input/devices` 中没有任何传感器类输入设备：

| device | name | 类型 |
|--------|------|------|
| event0 | gpio-keys | 音量键 |
| event1 | Goodix Capacitive TouchScreen | 触摸屏 |
| event2 | pm8xxx_vib_ffmemless | 振动马达 |
| event3 | pm8941_pwrkey | 电源键 |
| event4 | pm8941_resin | 复位键 |
| event5 | xiaomi-onclite Headset Jack | 耳机插孔 |

### 2. IIO 设备

仅有两个 PMIC ADC 设备：

```
iio:device0 → 200f000.spmi:pmic@0:adc@3100  (PM8941 ADC)
iio:device1 → 200f000.spmi:pmic@2:adc@3100  (PMI632 ADC)
```

无加速度计、磁力计、光感、接近传感器 IIO 设备。

### 3. I2C 总线状态

| I2C 总线 | 地址 | 状态 | 子设备 |
|-----------|------|:----:|--------|
| i2c@78b7000 | 0x78b7000 | **enabled** | touchscreen@14 (Goodix GT1158) |
| i2c@78b5000 | 0x78b5000 | disabled | — |
| i2c@78b6000 | 0x78b6000 | disabled | — |
| i2c@78b8000 | 0x78b8000 | disabled | — |
| i2c@7af5000 | 0x7af5000 | disabled | — |
| i2c@7af6000 | 0x7af6000 | disabled | — |
| i2c@7af7000 | 0x7af7000 | disabled | — |
| i2c@7af8000 | 0x7af8000 | disabled | — |

### 4. 传感器驱动模块可用性

内核已编译的传感器模块（位于 `/lib/modules/6.17.7-msm8953/kernel/drivers/iio/`）：

| 模块 | 驱动 | 支持的硬件 |
|------|------|-----------|
| `bmc150-accel-i2c.ko` | Bosch 加速度计 | BMC150/BMA2xx 系列 |
| `bmi160_i2c.ko` | Bosch IMU | BMI160 (加速度+陀螺仪) |
| `st_lsm6dsx_i2c.ko` | ST IMU | LSM6DSx 系列 |
| `stk3310.ko` | Sensortek | 接近+光线传感器 |
| `ltr501.ko` | Lite-On | 光线+接近传感器 |
| `ltrf216a.ko` | Lite-On | 光线传感器 |
| `yamaha-yas530.ko` | Yamaha | 磁力计 YAS530 系列 |
| `hid-sensor-accel-3d.ko` | HID 传感器 | 通用 HID 加速度计 |
| `hid-sensor-gyro-3d.ko` | HID 传感器 | 通用 HID 陀螺仪 |
| `hid-sensor-magn-3d.ko` | HID 传感器 | 通用 HID 磁力计 |
| `hid-sensor-als.ko` | HID 传感器 | 通用 HID 光线 |
| `hid-sensor-prox.ko` | HID 传感器 | 通用 HID 接近 |

**所有传感器模块均未加载**（`Used by 0` 或未出现在 `lsmod` 中），因为没有 DT 节点触发匹配。

### 5. 设备树搜索

在内核源码树中搜索常见的传感器 compatible 字符串，DTB 中完全没有匹配：
- 无 `bosch,bmi160` / `bosch,bmc150` / `st,lsm6dsx` 等 IMU
- 无 `sensortek,stk3310` / `liteon,ltr501` 等光感/接近
- 无 `yamaha,yas530` 等磁力计

### 6. 可工作的"传感器"

以下非用户传感器正常：

| 传感器 | 来源 | 值 |
|--------|------|-----|
| CPU 温度 | PMIC 热敏 | 多个 thermal zone |
| GPU 温度 | qcom tsens | tsens0-tsens14 |
| 电池/PMIC 温度 | PM8941/PMI632 ADC | — |
| 电池电压 | PM8941 ADC | — |

## 修复方案

### 已确认的硬件配置

来自 LineageOS `sensor_def_qcomdev.conf` (SDM632 参考平台，与 onclite 共享传感器配置):

| 信号 | GPIO | 说明 |
|------|------|------|
| I2C SDA | GPIO 14 | 传感器 I2C 数据线 |
| I2C SCL | GPIO 15 | 传感器 I2C 时钟线 |
| ACCEL INT | GPIO 42 | 加速度计中断 (DRI) |
| ALS/PRX INT | GPIO 43 | 光线/接近传感器中断 |
| MAG INT | GPIO 44 | 磁力计中断 |
| GYRO INT | GPIO 45 | 陀螺仪中断 (Redmi 7 无此传感器) |

传感器 I2C 地址（i2c-gpio 总线）:

| 传感器类型 | 可能芯片 | I2C 地址 |
|-----------|---------|---------|
| 加速度计 | bosch,bmi120 或 bosch,bmi160 | 0x68 |
| 光线+接近 | sensortek,stk3310 或 sensortek,stk3311 | 0x48 |
| 磁力计 | asahi-kasei,ak09911 或 asahi-kasei,ak09918 | 0x0C |

> **注意**: 传感器芯片型号基于 SDM632 参考平台配置和姊妹设备推断。
> Redmi 7 无陀螺仪，最可能的加速度计是 BMI120（纯加速度计）。
> 精确型号需从 stock ROM dtb 或 PCB 丝印确认。

### 方法一：直接修补 DTB（推荐）

在现有 DTB 上叠加传感器节点：

```bash
# 1. 从设备复制当前 DTB
scp mybays@192.168.1.159:/boot/sdm632-xiaomi-onclite.dtb /tmp/

# 2. 反编译
dtc -I dtb -O dts -o sdm632-xiaomi-onclite.dts sdm632-xiaomi-onclite.dtb

# 3. 编辑 DTS，在根节点 / {} 内添加以下内容:
```

```dts
// i2c-gpio 传感器总线 (GPIO 14=SDA, GPIO 15=SCL)
i2c-sensors {
    compatible = "i2c-gpio";
    sda-gpios = <&tlmm 14 (GPIO_ACTIVE_HIGH | GPIO_OPEN_DRAIN)>;
    scl-gpios = <&tlmm 15 (GPIO_ACTIVE_HIGH | GPIO_OPEN_DRAIN)>;
    i2c-gpio,delay-us = <2>;
    #address-cells = <1>;
    #size-cells = <0>;

    accelerometer@68 {
        compatible = "bosch,bmi120";
        reg = <0x68>;
        interrupt-parent = <&tlmm>;
        interrupts = <42 IRQ_TYPE_EDGE_RISING>;
        vdd-supply = <&pm8953_l10>;
        vddio-supply = <&pm8953_l6>;
        mount-matrix = "-2", "0",  "0",
                       "0",  "1",  "0",
                       "0",  "0",  "3";
    };

    light-sensor@48 {
        compatible = "sensortek,stk3310";
        reg = <0x48>;
        interrupt-parent = <&tlmm>;
        interrupts = <43 IRQ_TYPE_EDGE_RISING>;
        vdd-supply = <&pm8953_l10>;
        vddio-supply = <&pm8953_l6>;
    };

    magnetometer@c {
        compatible = "asahi-kasei,ak09911";
        reg = <0x0c>;
        vdd-supply = <&pm8953_l10>;
        vid-supply = <&pm8953_l6>;
        mount-matrix =  "1",  "0", "0",
                        "0", "-1", "0",
                        "0",  "0", "1";
    };
};
```

```bash
# 4. 编译回 DTB
dtc -I dts -O dtb -o sdm632-xiaomi-onclite-new.dtb sdm632-xiaomi-onclite.dts

# 5. 上传到设备并安装
scp sdm632-xiaomi-onclite-new.dtb mybays@192.168.1.159:/tmp/
ssh mybays@192.168.1.159
doas cp /boot/sdm632-xiaomi-onclite.dtb /boot/sdm632-xiaomi-onclite.dtb.bak
doas cp /tmp/sdm632-xiaomi-onclite-new.dtb /boot/sdm632-xiaomi-onclite.dtb
doas cp /tmp/sdm632-xiaomi-onclite-new.dtb /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb
doas reboot
```

### 方法二：验证传感器芯片

重启后加载相应驱动模块来测试：

```bash
# 加载传感器驱动
doas modprobe bmc150-accel-i2c    # BMI120 加速度计
doas modprobe bmi160_i2c           # BMI160 (备用)
doas modprobe stk3310              # 光线/接近
doas modprobe ak8975               # 磁力计

# 检查是否探测到传感器
dmesg | grep -i "bmi\|stk\|ak0\|accel\|light\|prox\|magnet"
ls /sys/bus/iio/devices/

# 如果设备出现，读取数据
cat /sys/bus/iio/devices/iio:device0/name
cat /sys/bus/iio/devices/iio:device0/in_accel_x_raw
```

### 备选芯片配置

如果默认配置不工作，尝试替换以下 compatible：

**加速度计备选**：
```dts
compatible = "bosch,bmi160";          // 替代 bmi120
compatible = "bosch,bmc150-accel";    // BMC150 通用系列
```

**光线/接近备选**：
```dts
compatible = "sensortek,stk3311";     // 替代 stk3310
compatible = "liteon,ltrf216a";       // Lite-On 光感 (仅光感,无接近)
compatible = "liteon,ltr501";         // Lite-On 光感+接近
reg = <0x53>;                         // LTR 系列通常在 0x53
```

**磁力计备选**：
```dts
compatible = "asahi-kasei,ak09918";   // 替代 ak09911
reg = <0x0d>;                         // AK09918 可能在 0x0D
compatible = "yamaha,yas537";         // Yamaha 磁力计
```

### 获取下游传感器信息的方法

如果需要确认精确的传感器型号：

```bash
# 方法 1: 从正常工作的 Android 系统获取
adb shell "cat /sys/bus/i2c/devices/*/name"
adb shell "cat /sys/bus/iio/devices/*/name"
adb shell "ls -la /sys/bus/i2c/devices/"

# 方法 2: 从 stock ROM dtb 提取
# 下载 Redmi 7 fastboot ROM, 解压后提取 boot.img 中的 dtb
# 用 split-appended-dtb 或 Android Image Kitchen 工具

# 方法 3: 拆机查看 PCB 芯片丝印 (最可靠)
# 传感器通常位于主板背面，靠近摄像头排线座附近
```

## 当前工作状态摘要

```
传感器功能状态:
  ✓ 加速度计 (LIS2HH12 @ 0x1D)                     — 完全工作! ST accel 驱动已加载
  ✓ 光线传感器 (STK33502 @ 0x47, STK3310 驱动)      — 基础工作
  ✓ 接近传感器 (STK33502 @ 0x47, STK3310 驱动)      — 基础工作
  ✓ 温度传感器 (thermal zones × 16, PMIC ADC)       — 工作
  ✓ PMIC 电压/电流 ADC                              — 工作
  ✗ 磁力计                                          — 硬件未检测到
  ✗ GPS/GNSS                                       — SIM 依赖 (另见 gps.md)
```

## 影响

- **屏幕自动旋转**：✅ **已可用** — iio-sensor-proxy 报告 `AccelerometerOrientation = "normal"`, `"right-up"` 等方向均正确
- **自动亮度**：待测试（光感已工作，iio-sensor-proxy 已检测到光感）
- **通话息屏**：待测试（接近传感器已工作）
- **指南针**：不可用（硬件无磁力计）
- **步数/运动追踪**：可用（加速度计已工作）

### Mount-Matrix 方向修正

LIS2HH12 芯片轴与设备物理轴一致（X=左右，Y=上下，Z=前后），但需要通过实测确定符号。

**修正方法**: 在不同姿态下读取芯片原始值来确定正确的矩阵：
| 设备姿态 | chip X | chip Y | chip Z | 说明 |
|---------|--------|--------|--------|------|
| 平放桌面（屏幕朝上） | -679 | 336 | **16492** | chip Z = 重力方向（向下穿过屏幕）|
| 竖持（屏幕朝向用户，顶部朝上）| -1232 | **-16060** | 123 | chip Y = 重力方向（向上）|

结论：chip 轴与设备轴自然对齐，无需交换轴。仅需确定各轴符号。

**迭代过程**:
| 版本 | Matrix | AccelerometerOrientation | 问题 |
|------|--------|-------------------------|------|
| v2 | `"0","1","0", "1","0","0", "0","0","-1"` | `"bottom-up"` | 轴交换 + 符号全错 |
| v3 | `"0","1","0", "-1","0","0", "0","0","1"` | `"bottom-up"` | 仍交换了 X/Y 轴 |
| v4 | `"1","0","0", "0","1","0", "0","0","1"` (identity) | `"normal"` | **X 轴左右翻转** |
| **v5** | **`"-1","0","0", "0","1","0", "0","0","1"`** | **`"normal"`** | **所有方向正确** |

**最终正确矩阵**（只对 X 轴取反）:
```
mount-matrix = "-1", "0", "0",
               "0",  "1", "0",
               "0",  "0", "1";
```
即: `IIO_X = -chip_X`, `IIO_Y = chip_Y`, `IIO_Z = chip_Z`

**经验教训**: 不要凭猜测构造 mount-matrix。正确做法是在已知姿态下实测芯片原始值，

确认 chip 轴与设备轴的对应关系后，逐步迭代验证。

## 修复组件

### DTB 修改

`/boot/sdm632-xiaomi-onclite.dtb` 已更新，添加 i2c-gpio 传感器总线:

```dts
i2c-sensors {
    compatible = "i2c-gpio";
    sda-gpios = <&tlmm 14 (GPIO_ACTIVE_HIGH | GPIO_OPEN_DRAIN)>;
    scl-gpios = <&tlmm 15 (GPIO_ACTIVE_HIGH | GPIO_OPEN_DRAIN)>;
    i2c-gpio,delay-us = <2>;
    #address-cells = <1>;
    #size-cells = <0>;

    accelerometer@1d {
        compatible = "st,lis2hh12";
        reg = <0x1d>;
        interrupt-parent = <&tlmm>;
        interrupts = <42 IRQ_TYPE_EDGE_RISING>;
        vdd-supply = <&pm8953_l10>;
        vddio-supply = <&pm8953_l6>;
        mount-matrix = "-1", "0", "0",
                       "0",  "1", "0",
                       "0",  "0", "1";
    };

    light-sensor@47 {
        compatible = "sensortek,stk3310";
        reg = <0x47>;
        interrupt-parent = <&tlmm>;
        interrupts = <43 IRQ_TYPE_EDGE_RISING>;
        vdd-supply = <&pm8953_l10>;
        vddio-supply = <&pm8953_l6>;
    };
};
```

### 内核模块 (`modules/`)

| 模块 | 用途 |
|------|------|
| `st_sensors.ko` | ST 传感器通用框架 |
| `st_sensors_i2c.ko` | ST 传感器 I2C 接口 |
| `st_accel.ko` | ST 加速度计核心 |
| `st_accel_i2c.ko` | ST 加速度计 I2C 驱动 (支持 lis2hh12) |

已安装到 `/lib/modules/6.17.7-msm8953/extra/`，开机自动加载 (`/etc/modules-load.d/st-accel.conf`).

### 编译方法

从 [msm8953-mainline/linux](https://github.com/msm8953-mainline/linux) tag `v6.17.7-r0` 编译:

```bash
# 1. 获取源码
git clone --depth 1 --branch v6.17.7-r0 https://github.com/msm8953-mainline/linux.git
cd linux

# 2. 应用内核配置并启用 ST accel
# 从设备复制: zcat /proc/config.gz > .config
echo "CONFIG_IIO_ST_ACCEL_3AXIS=m" >> .config
echo "CONFIG_IIO_ST_ACCEL_I2C_3AXIS=m" >> .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# 3. 编译 vmlinux + 模块 (LOCALVERSION="" 很重要!)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) LOCALVERSION="" vmlinux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) LOCALVERSION="" KBUILD_MODPOST_WARN=1 M=drivers/iio modules

# 4. 需要的 4 个文件:
# drivers/iio/accel/st_accel.ko
# drivers/iio/accel/st_accel_i2c.ko
# drivers/iio/common/st_sensors/st_sensors.ko
# drivers/iio/common/st_sensors/st_sensors_i2c.ko
```

> **重要**: `LOCALVERSION=""` 必须设置，否则 vermagic 会包含 `+` 后缀导致模块无法加载。内核 tag `v6.17.7-r0` 是轻量标签，setlocalversion 会错误地追加 `+`。

## USB Host (OTG) 修复

### 问题

插入 USB 设备后 `lsusb` 无任何显示，原因有两个：

1. **DWC3 卡在 gadget 模式** — DTB 中 `usb-role-switch` + 空的 `port@0` connector 导致角色切换永不完成，USB 永久工作在 peripheral 模式
2. **PMI632 VBUS 5V 未启用** — `usb-vbus-regulator@1100` 节点为 `status = "disabled"`

### DTB 修改

**修改 1**: 移除 `usb-role-switch`/`role-switch-default-mode`，改为直设 `dr_mode = "host"`:

```dts
// 删除:
usb-role-switch;
role-switch-default-mode = "peripheral";
ports { ... };  // 空的 connector 节点

// 添加:
dr_mode = "host";
```

**修改 2**: 启用 PMI632 VBUS 升压稳压器提供 5V 输出:

```dts
usb-vbus-regulator@1100 {
    compatible = "qcom,pmi632-vbus-reg", "qcom,pm8150b-vbus-reg";
    reg = <0x1100>;
    regulator-min-microamp = <500000>;
    regulator-max-microamp = <3000000>;
    regulator-always-on;
    status = "okay";   // 原为 "disabled"
};
```

### 验证

```bash
# 检查 VBUS 5V 是否启用
for d in /sys/class/regulator/regulator.*; do
    name=$(cat $d/name 2>/dev/null)
    [ "$name" = "usb_vbus" ] && echo "state=$(cat $d/state)"  # 应为 enabled
done

# 检查 xHCI 控制器
dmesg | grep xhci   # 应显示 xhci-hcd, root hub
lsusb                # 应列出 USB 设备
```

### 修改记录

| 修改 | DTS 文件 | 作用 |
|------|---------|------|
| sensors v2 → v5 | `sdm632-xiaomi-onclite-sensors-v2.dts` | 传感器 + mount-matrix 修正 |
| USB host | 同上, `usb@7000000` 节点 | dr_mode=host, VBUS 5V 启用 |

最终 DTB: `sdm632-xiaomi-onclite-usb-host-v2.dtb`

---

## 音频/外放扬声器修复

### 问题

声卡配置不完整，外放（扬声器）无法选择。通过 `aplay -l` 能看到播放设备，但 `amixer` 缺少扬声器相关控件。

### 根本原因分析

Redmi 7 使用两个音频组件：

1. **PM8916 WCD 模拟编解码器** (`msm8916-wcd-analog`) — SoC 内置的 PMIC 音频 codec  
2. **AW87329/AW8738 扬声器放大器** (`awinic,aw8738`) — 外部 GPIO 控制的扬声器功放芯片

原 DTS 缺少：
- AW8738 扬声器放大器 DT 节点
- 声卡 (`sound_card`) 中的扬声器 widget、pin-switch、audio-routing 和 aux-devs 配置

### AW8738 功放芯片

AW8738 是一个简单的 GPIO 控制 K 类音频放大器：
- **mode-gpios**: 控制功放模式/增益的 GPIO 引脚
- **awinic,mode**: 增益模式（上电时 GPIO 脉冲次数），取值 1-5
- **sound-name-prefix**: DAPM widget 名称前缀，用于 audio-routing

AW8738 驱动的 DAPM 路径：
```
IN → DRV → OUT
```
其中 `DRV` widget 触发 GPIO 脉冲控制功放增益。

### DTS 修改

**修改 1**: 添加 AW8738 扬声器放大器节点:

```dts
speaker_amp: audio-amplifier {
    compatible = "awinic,aw8738";
    mode-gpios = <&tlmm 96 GPIO_ACTIVE_HIGH>;  // 0x60 = GPIO 96
    awinic,mode = <5>;                          // 增益模式 5（与 markw 相同）
    sound-name-prefix = "Speaker Amp";
};
```

**修改 2**: 更新声卡节点添加扬声器配置:

```dts
&sound_card {
    widgets = "Speaker", "Speaker";       // 动态创建 Speaker DAPM widget
    pin-switches = "Speaker";             // 创建扬声器引脚开关
    aux-devs = <&speaker_amp>;            // 关联外部功放
    audio-routing = ...,
        "Speaker", "Speaker Amp OUT",     // 声卡 Speaker ← AW8738 输出
        "Speaker Amp IN", "SPK_OUT";      // AW8738 输入 ← WCD codec SPK_OUT
};
```

### 音频信号路径

```
WCD Codec (PM8916):
  SPK DAC → SPKR_CLK → RX_BIAS → SPK PA → SPK_OUT
    ↓ audio-routing: "Speaker Amp IN" ← "SPK_OUT"
AW8738 功放:
  Speaker Amp IN → Speaker Amp DRV → Speaker Amp OUT
    ↓ audio-routing: "Speaker" ← "Speaker Amp OUT"
声卡:
  Speaker (DAPM SPK widget)  ← 用户空间可控制
```

### 部署步骤

```bash
# 1. 编译 DTB
dtc -I dts -O dtb -o sdm632-xiaomi-onclite-speaker-fix.dtb \
    sdm632-xiaomi-onclite-sensors-v2.dts

# 2. 安装 DTB（在设备上执行）
doas cp sdm632-xiaomi-onclite-speaker-fix.dtb /boot/sdm632-xiaomi-onclite.dtb

# 3. 加载 AW8738 模块（如果尚未加载）
doas modprobe snd-soc-aw8738

# 4. 重启
doas reboot
```

### 验证

```bash
# 检查 AW8738 驱动是否加载
lsmod | grep aw8738

# 检查声卡 DAPM widgets（应有 "Speaker" widget）
find /sys/kernel/debug/asoc -name "dapm" -exec ls {} \;

# 通过 tinymix 查看控件（应有 "Speaker" 控件）
tinymix | grep -i speaker

# 测试扬声器输出
speaker-test -t sine -f 440 -l 0    # 需要先选择 Speaker 输出
```

### 注意事项

- **AW8738 模块**: 内核已编译 `CONFIG_SND_SOC_AW8738=m`，模块位于 `/lib/modules/6.17.7-msm8953/kernel/sound/soc/codecs/snd-soc-aw8738.ko`
- **WCD 编解码器模块**: 需确保 `snd-soc-msm8916-wcd-analog` 和 `snd-soc-msm8916-wcd-digital` 已加载
- **GPIO 96**: 这是基于 Xiaomi MSM8953 设备常见配置（markw 等使用 GPIO 96）。如果扬声器无声音，可能需要调整 GPIO 引脚号
- **awinic,mode=5**: 增益模式 5 是最常见配置（markw、mido 等使用）。Redmi S2/Y2 (ysl) 使用 mode=2

### 修改记录

| 修改 | DTS 文件 | 作用 |
|------|---------|------|
| sensors v2 → v5 | `sdm632-xiaomi-onclite-sensors-v2.dts` | 传感器 + mount-matrix 修正 |
| USB host | 同上, `usb@7000000` 节点 | dr_mode=host, VBUS 5V 启用 |
| 音频/扬声器 | 同上, 添加 `speaker_amp` + 更新 `sound_card` | AW8738 功放 + Speaker DAPM widget |

最终 DTB: `sdm632-xiaomi-onclite-speaker-fix.dtb`

---

## 电池/充电器修复

### 问题

电池无法识别 — `/sys/class/power_supply/` 目录为空，没有任何电源设备。

### 根本原因

PMI632 (Redmi 7 的电源管理 IC) 在 mainline 内核中缺少充电器和电量计 DT 节点。驱动已编译进内核 (`CONFIG_CHARGER_QCOM_SMBCHG=y`、`CONFIG_BATTERY_PMI8994_FG=y`) 但 DTS 中没有相应的设备节点。

### DTS 修改

**修改 1**: 添加 `simple-battery` 节点 (4000mAh):

```dts
battery {
    compatible = "simple-battery";
    charge-full-design-microamp-hours = <4000000>;
    constant-charge-current-max-microamp = <1000000>;
    voltage-min-design-microvolt = <3400000>;
    voltage-max-design-microvolt = <4380000>;
    phandle = <0xca>;
};
```

**修改 2**: 添加 charger@1000 节点（基于 pmi8950.dtsi 参考）:

```dts
charger@1000 {
    compatible = "qcom,pmi8996-smbchg";
    reg = <0x1000>;
    interrupts = <...>;           // 31 个中断完整列表
    interrupt-names = "chg-error", ...;
    monitored-battery = <&battery>;
    smbchg-lite;
    status = "okay";
};
```

**修改 3**: 添加 fuel-gauge@4000 节点:

```dts
fuel-gauge@4000 {
    compatible = "qcom,pmi8996-fg";
    reg = <0x4000>;
    interrupts = <0x2 0x40 0x4 IRQ_TYPE_EDGE_RISING>,
                 <0x2 0x44 0x0 IRQ_TYPE_EDGE_BOTH>;
    interrupt-names = "soc-delta", "mem-avail";
    status = "okay";
};
```

### 修复状态

| 组件 | 状态 | 说明 |
|------|------|------|
| **充电器** | ✅ 已工作 | `qcom-smbchg-usb` 电源设备已注册，USB 类型检测正常 |
| **电量计** | ❌ 不工作 | `pmi8994-fg` 驱动与 PMI632 硬件寄存器不兼容 (0x452 寄存器不存在) |

### 充电器当前状态

```
# cat /sys/class/power_supply/qcom-smbchg-usb/uevent
POWER_SUPPLY_NAME=qcom-smbchg-usb
POWER_SUPPLY_TYPE=USB
POWER_SUPPLY_STATUS=Discharging
POWER_SUPPLY_CHARGE_TYPE=Fast
POWER_SUPPLY_HEALTH=Good
POWER_SUPPLY_CONSTANT_CHARGE_CURRENT=2200000
POWER_SUPPLY_CONSTANT_CHARGE_CURRENT_MAX=1000000
POWER_SUPPLY_INPUT_CURRENT_LIMIT=100000
```

- 插入 USB 后会显示 `STATUS=Charging`、`PRESENT=1`、`ONLINE=1`
- USB 类型自动检测 (SDP/DCP/CDP) 也会显示充电器类型

### 电量计问题分析

`pmi8994_fg.c` 驱动在 probe 时尝试写入寄存器 `MEM_INTF_IMA_CFG (0x452)`:

```
qcom-pmi8994-fg: Failed to configure interrupt sourete: -19 (ENODEV)
```

PMI632 的燃料计 IP 与 PMI8994/PMI8996 不同，寄存器地址不同。解决方法：
1. **优先方案**: 从 Android 下游内核找到 PMI632 燃料计的正确寄存器映射，在 `pmi8994_fg.c` 中添加 PMI632 支持
2. **替代方案**: 检查是否有独立的 PMI632 燃料计驱动程序可用
3. **临时方案**: 依赖充电器状态（Charging/Discharging）判断电源连接，无法读取电池百分比

### 修改记录

| 修改 | DTS 文件 | 作用 |
|------|---------|------|
| sensors v2 → v5 | `sdm632-xiaomi-onclite-sensors-v2.dts` | 传感器 + mount-matrix 修正 |
| USB host | 同上, `usb@7000000` 节点 | dr_mode=host, VBUS 5V 启用 |
| 音频/扬声器 | 同上, 添加 `speaker_amp` + 更新 `sound_card` | AW8738 功放 + Speaker DAPM widget |
| 电池/充电器 | 同上, 添加 `battery` + `charger@1000` + `fuel-gauge@4000` | 充电器工作，电量计需内核改动 |

最终 DTB: `sdm632-xiaomi-onclite-battery-fix.dtb`

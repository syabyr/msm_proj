# PMS 26.06 触摸屏修复文档

## 设备信息

| 项目 | 值 |
|------|-----|
| 设备型号 | Xiaomi Redmi 7 (onclite) |
| SoC | Qualcomm SDM632 (MSM8953) |
| OS | postmarketOS 26.06 |
| 内核 | 7.0.9-msm8953 |
| 触摸 IC | Goodix GT1158 |
| SSH | mybays@172.16.42.1 |

## 问题

PMS 26.06 默认 DTB 中触摸屏配置错误，导致系统启动后触摸屏完全无响应。

## 根因分析

共发现两个问题：

### 问题 1: 驱动和 I2C 地址不匹配

| 项目 | 原 DTB (错误) | 实际情况 (正确) |
|------|-------------|--------------|
| 兼容驱动 | `edt,edt-ft5406` | `goodix,gt1158` |
| I2C 地址 | `0x38` | `0x14` |
| 模拟供电属性名 | `vcc-supply` | `AVDD28-supply` |
| IO 供电属性名 | `iovcc-supply` | `VDDIO-supply` |

Xiaomi Redmi 7 实际搭载的是 **Goodix GT1158** 触摸屏控制器（I2C 地址 0x14），
而 DTB 配置为 EDT FT5406（I2C 地址 0x38），导致驱动无法匹配。

### 问题 2: reset-gpios 极性标志不兼容

`reset-gpios` 原有标志为 `GPIO_ACTIVE_LOW` (0x01)，但 goodix 驱动使用逻辑电平
GPIO 函数（`gpiod_direction_output` 而非 `_raw` 变体）。在 active-low 模式下，
驱动设置 "逻辑 0" 时硬件输出高电平，导致复位序列反转 —— 触摸控制器在上电后
立即被置于复位状态，I2C 通信失败 (-6 ENXIO)。

修改为 `GPIO_ACTIVE_HIGH` (0x00) 后，驱动逻辑电平与硬件电平一致，复位序列正确。

## 修复内容

修改 `/boot/sdm632-xiaomi-onclite.dtb` 中的触摸屏节点：

```diff
- touchscreen@38 {
-     compatible = "edt,edt-ft5406";
-     reg = <0x38>;
-     vcc-supply = <0x8c>;
-     iovcc-supply = <0x46>;
-     reset-gpios = <0x39 0x40 0x01>;   /* GPIO_ACTIVE_LOW */
+ touchscreen@14 {
+     compatible = "goodix,gt1158";
+     reg = <0x14>;
+     AVDD28-supply = <0x8c>;
+     VDDIO-supply = <0x46>;
+     irq-gpios = <0x39 0x41 0x02>;
+     reset-gpios = <0x39 0x40 0x00>;   /* GPIO_ACTIVE_HIGH */
```

供电引用不变：L6 (phandle 0x46, 1.8V) = VDDIO, L10 (phandle 0x8c, 2.8V) = AVDD28。

## 操作步骤

```bash
# 1. 从设备复制原始 DTB
scp mybays@172.16.42.1:/boot/sdm632-xiaomi-onclite.dtb /tmp/original.dtb

# 2. 反编译
dtc -I dtb -O dts -o original.dts original.dtb

# 3. 修改 DTS（见上方 diff）

# 4. 编译
dtc -I dts -O dtb -o fixed.dtb fixed.dts

# 5. 推送到设备
scp fixed.dtb mybays@172.16.42.1:/tmp/

# 6. 安装（在设备上）
sudo cp /boot/sdm632-xiaomi-onclite.dtb /boot/sdm632-xiaomi-onclite.dtb.bak
sudo cp /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb.bak
sudo cp /tmp/fixed.dtb /boot/sdm632-xiaomi-onclite.dtb
sudo cp /tmp/fixed.dtb /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb

# 7. 重启
sudo reboot
```

## 修复结果

```
[   16.865859] Goodix-TS 0-0014: Error reading 1 bytes from 0x8140: -110  (瞬态超时)
[   16.892332] Goodix-TS 0-0014: ID 1158, version: 0006
[   16.916148] input: Goodix Capacitive TouchScreen as .../0-0014/input/input1
```

GPIO 状态：
```
gpio64: out high func0 8mA pull up   (reset 已释放)
gpio65: in  low  func0 8mA pull up   (IRQ 就绪)
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `sdm632-xiaomi-onclite-original.dtb` | PMS 26.06 原始 DTB（错误配置） |
| `sdm632-xiaomi-onclite-original.dts` | 原始 DTS（反编译自原始 DTB） |
| `sdm632-xiaomi-onclite-touchscreen-fixed.dtb` | 第一版修复 DTB（仅改驱动，GPIO 标志未改） |
| `sdm632-xiaomi-onclite-touchscreen-fixed.dts` | 第一版修复 DTS |
| `sdm632-xiaomi-onclite-touchscreen-fixed-v2.dtb` | 最终修复 DTB（含 GPIO 标志修复） |
| `sdm632-xiaomi-onclite-touchscreen-fixed-v2.dts` | 最终修复 DTS |
| `touchscreen-fix.md` | 本文档 |

## MD5 校验

| 文件 | MD5 |
|------|-----|
| 原始 DTB | `0c20ddc4843f96053a389f5681e2c76d` |
| 修复 DTB (v1) | `7b1674e53ccf72f5f73b4b481897af10` |
| 修复 DTB (v2, final) | (最终版本) |

## 已知遗留问题

```
Direct firmware load for goodix_1158_cfg.bin failed with error -2
```

缺少 Goodix GT1158 配置文件固件。芯片使用内置默认配置工作，触摸功能正常。

## 日期

2026-07-12

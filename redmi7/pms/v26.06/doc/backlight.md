# Redmi 7 (onclite) 背光问题分析

## 现象

`/sys/class/backlight/1a94000.dsi.0/brightness` 可以读写，值能改变（0-255），但**屏幕亮度无实际变化**。

## 硬件架构

Redmi 7 有三套面板 SKU：

| 驱动文件 | compatible | 背光方式 | max_brightness |
|---------|------------|---------|---------------|
| panel-xiaomi-onclite-otm1901a.c | xiaomi,onclite-otm1901a | DCS (0x51) | 255 |
| panel-xiaomi-onclite-hx8394f.c | xiaomi,onclite-hx8394f | DCS (0x51) | 255 |
| panel-xiaomi-onclite-ili9881.c | xiaomi,onclite-ili9881 | DCS large (0x51) | 4095 |

当前设备使用的是 **otm1901a** (CSOT/Truly 面板)。

## 下游内核参考

```dts
// dsi-panel-truly-otm1901a-720p-video.dtsi
qcom,mdss-dsi-bl-pmic-control-type = "bl_ctrl_dcs";
qcom,mdss-dsi-bl-min-level = <1>;
qcom,mdss-dsi-bl-max-level = <255>;
```

```dts
// pmi632.dtsi
pmi632_pwm: qcom,pwms@b300 {
    compatible = "qcom,pwm-lpg";
    #pwm-cells = <2>;
    // channels for RGB LED + LCD backlight
};
```

下游虽然标注 `bl_ctrl_dcs`，但 PMI632 有 LPG PWM 通道可驱动 LCD 背光 LED。

## 排查过程

### 1. DCS 命令确实发出了

在 `bl_update_status` 中添加 `dev_info`，确认每次写 brightness 都触发回调，`mipi_dsi_dcs_set_display_brightness()` 返回 0（成功）。

### 2. 实测 DCS 命令不改变 LED 背光

```bash
echo 1   > brightness  # 屏幕亮度无变化
echo 255 > brightness  # 屏幕亮度无变化
```

### 3. 尝试修改 Display Control Register

`MIPI_DCS_WRITE_CONTROL_DISPLAY` (0x53) 初始化值：

| 值 | bit 2 (CTRL) | bit 0 (BL) | 含义 |
|----|-------------|-----------|------|
| 0x24 | 1 | 0 | DCS 亮度映射启用，LED 背光=外部 PWM |
| 0x25 | 1 | 1 | DCS 亮度映射启用，LED 背光=DCS 控制 |

将 init 序列从 `0x24` 改为 `0x25`，**无效**。

### 4. 尝试 pwm-backlight

添加 DT 节点引用 `pmi632_lpg` channel 3，面板也引用 backlight。结果：
- PWM 申请成功，通道 enabled
- `duty_cycle = 0` — 亮度始终 0%
- LPG PWM 输出正常但 duty 不随 brightness 变化
- 原因：pwm-backlight 的 `compute_duty_cycle` 依赖 `brightness-levels` 表做插值，与面板期望的 0-255 值不匹配

### 5. 根本原因

**PMI632 WLED/LPG 在主线的背光驱动支持不完整。**

```
下游:  PMI632 LPG PWM → 外部升压驱动 (lcdb) → LCD LED 背光
主线:  PMI632 LPG PWM → 仅支持 LED 呼吸灯，无背光 WLED 模式
```

- `CONFIG_BACKLIGHT_QCOM_WLED=y` 但只支持 `pm8941/pmi8950/pmi8994/pmi8998/pm660l/pm6150l/pm8150l`，**不支持 pmi632**
- onclite 面板的 DCS 亮度命令 (0x51) 只控制**内容亮度映射**（gamma 曲线），不控制 LED 电流

### 6. DCS Brightness Control 的 MIPI 规范

```
0x51 MIPI_DCS_SET_DISPLAY_BRIGHTNESS
  - 控制显示模块的亮度映射表
  - 不直接控制 LED 背光电流
  - 背光 LED 电流由 0x53 bit 0 (BL) 选择来源
```

当 `0x53 BL=0`：LED 背光由外部 PWM/GPIO 控制，0x51 只调节 gamma
当 `0x53 BL=1`：LED 背光跟随 0x51 值（如果面板硬件支持）

改为 `0x25` 无效说明该面板**硬件不支持 DCS 控制 LED 背光**，必须外部 PWM。

## 修复方向

### 方案 A：主线 WLED 驱动添加 PMI632 支持

修改 `drivers/video/backlight/qcom-wled.c`，参照 `qcom,pmi8950-wled` 的处理方式添加 PMI632 兼容性。PMI632 的 LPG 硬件类似 PMI8950 的 WLED 但只有 3 通道。

**复杂度：高**

### 方案 B：面板驱动改用 pwm-backlight + LPG

修改 otm1901a 驱动，移除自建 DCS backlight，改为 `devm_of_find_backlight()` 从 DT 获取，配合 `pwm-backlight` 节点使用 PMI632 LPG 通道。

**需要解决：**
1. LPG 通道申请已被 LED 占用时需协调
2. brightness 值到 PWM duty 的映射需要适配
3. 可能需要 `enable-gpios` 控制背光使能脚

**复杂度：中**

### 方案 C（推荐短期）：gpio-backlight

如果面板背光使能只是 GPIO 开关（非 PWM 调光），可以用 `gpio-backlight` 驱动实现开关控制。

**需要确认：** 硬件上背光是否是 PWM 调光 vs GPIO 开关

## 相关文件

| 文件 | 说明 |
|------|------|
| `drivers/gpu/drm/panel/msm8953-generated/panel-xiaomi-onclite-otm1901a.c:592` | 0x53 init（已改为 0x25，无效） |
| `drivers/video/backlight/qcom-wled.c` | WLED 驱动，不支持 pmi632 |
| `drivers/leds/rgb/leds-qcom-lpg.c` | PMI632 LPG PWM 驱动 |
| `arch/arm64/boot/dts/qcom/pmi632.dtsi:207-219` | LPG DT 节点 |
| `arch/arm64/boot/dts/qcom/sdm632-xiaomi-onclite.dts` | onclite 设备树 |

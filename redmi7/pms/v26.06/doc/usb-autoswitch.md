# USB Host/Device 切换分析 — Redmi 7 (onclite) PMS 26.06

## 1. USB Host 和 Device 是如何切换的

### 当前机制：`usb-role-switch` + DWC3 dual-role

当前 DTB (`onclite-current.dts`) 中 USB 节点配置：

```dts
usb@7000000 {
    compatible = "qcom,msm8953-dwc3", "qcom,snps-dwc3";
    usb-role-switch;                          // 启用 role-switch 框架
    role-switch-default-mode = "peripheral";   // 默认 = device/gadget 模式
    maximum-speed = "high-speed";
    ...
};
```

内核编译选项：
- `CONFIG_USB_DWC3_DUAL_ROLE=y` — DWC3 控制器支持 dual-role（host + device）
- `CONFIG_USB_ROLE_SWITCH=y` — 支持 role-switch 框架
- `CONFIG_USB_CONFIGFS=y` — USB gadget configfs（用于 USB 网络共享）

### 切换流程

- **Role switch 需要配对设备**：`usb-role-switch` 属性声明了一个 role-switch 端点，期望有另一个驱动（如 Type-C controller、extcon、或 GPIO ID pin 检测）通过 sysfs 写入 `"host"` 或 `"device"` 来触发切换
  - sysfs 路径：`/sys/devices/platform/soc@0/7000000.usb/usb_role/7000000.usb-role-switch/role`
  - 当前值：`device`
- **当前状态**：`waiting_for_supplier = 0`（不等待供应商），但实际没有伙伴驱动绑定，因此始终保持在默认的 `peripheral` 模式
- **没有 extcon**：`/sys/class/extcon/` 为空，没有 USB ID pin 检测驱动
- **PMI632 Type-C 被禁用**：DTS 中 `pmi632-typec` 和 `pmi632-vbus-reg` 都是 `status = "disabled"`

### 之前的 USB Host DTB 修改（PMS 25.12 时期的解决方案）

```dts
// 将:
usb-role-switch;
role-switch-default-mode = "peripheral";
// 改为:
dr_mode = "host";
```

这是**静态硬切换**：直接用 `dr_mode = "host"` 覆盖 dual-role，强制 DWC3 进入 host-only 模式。

已有文件：
- `sdm632-xiaomi-onclite-usb-host.dtb` — USB host 模式 DTB
- `sdm632-xiaomi-onclite-usb-host-v2.dtb` — USB host 模式 DTB v2

### 手动切换方法

```bash
# 切换到 host 模式（需要 USB 线缆 OTG 适配器，ID pin 接地）
echo "host" | sudo tee /sys/devices/platform/soc@0/7000000.usb/usb_role/7000000.usb-role-switch/role

# 切换回 device/gadget 模式
echo "device" | sudo tee /sys/devices/platform/soc@0/7000000.usb/usb_role/7000000.usb-role-switch/role
```

注意：手动切换后 USB gadget 网络（172.16.42.1）会断开，需要重新配置。

## 2. 能不能自动切换

**不能，且需要满足多个前提条件：**

| 条件 | 状态 | 说明 |
|------|------|------|
| DWC3 dual-role | 已支持 | `CONFIG_USB_DWC3_DUAL_ROLE=y` |
| USB role-switch 框架 | 已启用 | `CONFIG_USB_ROLE_SWITCH=y`，DTB 有 `usb-role-switch` |
| ID pin 检测 (extcon) | **缺失** | Redmi 7 的 Micro-USB 接口第4脚 (ID pin) 连接到 PMI632，但 PMI632 的 Type-C/CC 检测驱动被禁用 |
| Type-C controller | **禁用** | `pmi632-typec` 状态为 `disabled` |
| VBUS regulator | **禁用** | `pmi632-vbus-reg` 状态为 `disabled` |

### 根本原因

Redmi 7 的 USB 接口是 Micro-USB（不是 Type-C），ID pin 通过 PMI632 PMIC 检测。但 PMI632 的 VBUS regulator 和 Type-C 检测驱动在 mainline 内核中要么未合入，要么与 msm8953 平台适配不完整。

下游 Android 内核使用 `qpnp-smbcharger` (smbcharger) 驱动来处理充电 + OTG 检测，该驱动位于：
```
drivers/power/supply/qcom/qpnp-smbcharger.c
```
compatible string: `"qcom,qpnp-smbcharger"`

但该驱动未移植到 mainline 内核。

### 理论上实现自动切换需要

1. 启用 PMI632 VBUS regulator 和 Type-C 节点（改 DTB `status = "okay"`）
2. 移植或适配 PMI632 charger/OTG 驱动到 mainline（`qpnp-smbcharger` 或 `pmi632_charger`）
3. 让 charger 驱动注册为 usb-role-switch 的伙伴，根据 ID pin 电平自动触发 role 切换

### 当前设备 SPMI 总线状态

```
SPMI devices:
  0-00: qcom,pm8953   (主 PMIC)
  0-01: qcom,pm8953   (主 PMIC slave)
  0-02: qcom,pmi632   (充电/电源管理 PMIC)
  0-03: qcom,pmi632   (充电/电源管理 PMIC slave)

PMI632 已绑定的驱动:
  - qcom,spmi-adc5      (ADC)
  - qcom,spmi-temp-alarm (温度报警)
  - qcom,spmi-vadc       (电压 ADC)
  - qcom,spmi-gpio       (GPIO)

PMI632 缺失的驱动:
  - qcom,pmi632-vbus-reg (VBUS regulator — DTB 中 disabled)
  - qcom,pmi632-typec    (Type-C detection — DTB 中 disabled)
  - qcom,qpnp-smbcharger (充电 + OTG — 未移植)
```

## 3. Host 模式下能不能充电

**不能。** 原因如下：

### 硬件层面

Micro-USB OTG 规范中，当设备作为 host（ID pin 接地）时，VBUS 由**设备端向外供电**（给外接的 USB 设备供电，如 U盘、键盘等）。此时 VBUS 是输出方向，充电 IC 的输入通路不会激活。

### 软件/驱动层面

- **没有充电驱动**：`/sys/class/power_supply/` 完全为空，系统中没有任何 charger/battery driver
- PMI632 的 charger 部分未驱动：内核虽有 `CONFIG_SPMI=y` 和 PMIC 基础支持，但 `qpnp-smbcharger` / `smb5` charger 驱动未编译/未加载
- SPMI 总线上 PMI632 (0-02, 0-03) 仅绑定了 ADC、GPIO、temp-alarm 等外设，没有 charger 驱动绑定

### 总结

即使切换到 host 模式（通过 `dr_mode = "host"` DTB），充电也无法工作，因为：
1. Micro-USB OTG host 模式下，VBUS 是**设备向外输出**的，物理上不会从 USB 口取电
2. PMI632 charger 驱动缺失，即使接充电器也无法检测和取电

当前 device 模式下的充电状态：系统作为 USB gadget（peripheral mode）连接 PC 时，理论上可以从 VBUS 取电（PC 的 USB 口供电），但由于没有 charger 驱动，系统无法报告充电状态。这也是为什么 pmOS wiki 中标记 `status_battery = N` 和 `status_otg = N` 的原因。

## 附录：相关文件

- 当前 DTB：`/mnt/2T/temp/build/pms/redmi7/onclite-current.dts`
- USB Host DTB v1：`/mnt/2T/temp/build/pms/redmi7/sdm632-xiaomi-onclite-usb-host.dtb`
- USB Host DTB v2：`/mnt/2T/temp/build/pms/redmi7/sdm632-xiaomi-onclite-usb-host-v2.dtb`
- 下游内核 charger 驱动：`backup-20260711/android_kernel_xiaomi_onclite/drivers/power/supply/qcom/qpnp-smbcharger.c`
- 下游内核 PMI632 charger：`backup-20260711/android_kernel_xiaomi_onclite/drivers/power/supply/qcom/qpnp-smb5.c` (chg->name = "pmi632_charger")

## 附录：USB Host 模式 DTB diff

```diff
# 原始（device/peripheral 模式）:
  usb@7000000 {
-     usb-role-switch;
-     role-switch-default-mode = "peripheral";
      ...
  };

# USB Host DTB 修改:
  usb@7000000 {
+     dr_mode = "host";
      ...
  };
```

移除 `usb-role-switch` 和 `role-switch-default-mode`，替换为 `dr_mode = "host"`，静态强制 host 模式。

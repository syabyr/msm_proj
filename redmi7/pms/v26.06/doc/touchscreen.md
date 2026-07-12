# Xiaomi Redmi 7 (onclite) 触摸屏调试文档

## 设备信息

| 项目 | 值 |
|------|-----|
| 设备型号 | Xiaomi Redmi 7 |
| 设备代号 | onclite |
| SoC | Qualcomm MSM8953 (SDM632) |
| OS | postmarketOS |
| 内核 | 6.17.7-msm8953 |
| 触摸IC | Goodix GT1158 |
| 显示面板 | xiaomi,onclite-otm1901a |
| SSH | mybays@172.16.42.1 |

## 问题现象

系统启动后触摸屏完全无响应。`/proc/bus/input/devices` 中没有触摸输入设备。

## 根因

**设备树 (DTB) 配置了错误的触摸控制器驱动。**

| 项目 | 原 DTB (错误) | 实际情况 (正确) |
|------|-------------|--------------|
| 兼容驱动 | `edt,edt-ft5406` | `goodix,gt1158` |
| I2C 地址 | `0x38` | `0x14` |
| 供电属性名 | `vcc-supply` / `iovcc-supply` | `AVDD28-supply` / `VDDIO-supply` |

Xiaomi Redmi 7 实际搭载的是 **Goodix GT1158** 触摸屏控制器（位于 I2C 地址 0x14），
而非 EDT FT5406（位于 I2C 地址 0x38）。

`edt_ft5x06` 驱动尝试在 I2C 地址 `0x38` 进行通信，但该地址无设备响应，
导致 probe 每次都失败：
```
[    1.824636] edt_ft5x06 0-0038: touchscreen probe failed
```

## 调试过程

### 1. 查看输入设备
```bash
cat /proc/bus/input/devices
```
输出中没有任何触摸屏设备，只有 gpio-keys、pm8941_pwrkey、pm8941_resin 等。

### 2. 查看内核日志
```bash
dmesg | grep -i "touch\|ft5x\|goodix"
```
发现关键错误：
```
edt_ft5x06 0-0038: touchscreen probe failed
```

### 3. 确认驱动模块状态
```bash
lsmod | grep edt_ft5x06
```
输出：`edt_ft5x06  32768  0` — Used by 0，说明模块已加载但未绑定到任何设备。

### 4. 扫描 I2C 总线
```bash
# 需要 root 权限
python3 -c "
import os, fcntl
I2C_SLAVE = 0x0703
fd = os.open('/dev/i2c-0', os.O_RDWR)
for addr in range(0x03, 0x78):
    try:
        fcntl.ioctl(fd, I2C_SLAVE, addr)
        os.write(fd, bytes([0x00]))
        os.read(fd, 1)
        print(f'0x{addr:02x}')
    except:
        pass
os.close(fd)
"
```
只有 `0x14` 有设备响应，`0x38` 无响应。

### 5. 识别触摸IC身份
```bash
# 读取 Goodix 配置寄存器
fcntl.ioctl(fd, I2C_SLAVE, 0x14)
os.write(fd, bytes([0x81, 0x40]))  # Goodix GT 配置区地址
data = os.read(fd, 4)              # 返回 0x31313538 = "1158"
```
确认芯片型号为 **GT1158**。

### 6. 验证芯片型号
```bash
modinfo goodix_ts | grep "gt1158"
```
确认 `goodix_ts` 驱动支持 GT1158：`alias: of:N*T*Cgoodix,gt1158`。

## 修复方法

### 修复后的 DTB 节点内容
```dts
touchscreen@14 {
    compatible = "goodix,gt1158";
    reg = <0x14>;
    interrupt-parent = <0x39>;
    interrupts = <0x41 0x02>;
    pinctrl-0 = <0x86 0x87>;
    pinctrl-1 = <0x88 0x89>;
    pinctrl-names = "default", "sleep";
    reset-gpios = <0x39 0x40 0x01>;
    irq-gpios = <0x39 0x41 0x02>;
    AVDD28-supply = <0x8a>;
    VDDIO-supply = <0x46>;
    touchscreen-size-x = <0x2d0>;  /* 720 */
    touchscreen-size-y = <0x5f0>;  /* 1520 */
    status = "okay";
};
```

### 操作步骤

```bash
# 1. 从设备复制 DTB
scp mybays@172.16.42.1:/boot/sdm632-xiaomi-onclite.dtb /tmp/

# 2. 反编译为 DTS
dtc -I dtb -O dts -o sdm632-xiaomi-onclite.dts sdm632-xiaomi-onclite.dtb

# 3. 编辑 DTS，将 touchscreen@38 节点改为 touchscreen@14
#    修改 compatible、reg、供电属性名，添加 irq-gpios

# 4. 编译回 DTB
dtc -I dts -O dtb -o sdm632-xiaomi-onclite-fixed.dtb sdm632-xiaomi-onclite.dts

# 5. 上传到设备并替换
scp sdm632-xiaomi-onclite-fixed.dtb mybays@172.16.42.1:/tmp/

# 6. 备份原 DTB
sudo cp /boot/sdm632-xiaomi-onclite.dtb /boot/sdm632-xiaomi-onclite.dtb.bak

# 7. 安装新 DTB
sudo cp /tmp/sdm632-xiaomi-onclite-fixed.dtb /boot/sdm632-xiaomi-onclite.dtb
sudo cp /tmp/sdm632-xiaomi-onclite-fixed.dtb /boot/dtbs/qcom/sdm632-xiaomi-onclite.dtb

# 8. 重启
sudo reboot
```

## 修复结果

重启后内核日志：
```
[   16.634513] Goodix-TS 0-0014: ID 1158, version: 0006
[   16.657807] input: Goodix Capacitive TouchScreen as /devices/.../0-0014/input/input1
```

`/proc/bus/input/devices`：
```
I: Bus=0018 Vendor=0416 Product=0486 Version=0006
N: Name="Goodix Capacitive TouchScreen"
P: Phys=input/ts
S: Sysfs=/devices/platform/soc@0/78b7000.i2c/i2c-0/0-0014/input/input1
H: Handlers=kbd event1
B: PROP=2
B: EV=b
```

## 已知遗留问题

```
Direct firmware load for goodix_1158_cfg.bin failed with error -2
```

缺少 Goodix GT1158 的配置文件固件。芯片使用内置默认配置工作，
触摸功能正常，但如需优化灵敏度/精度等参数，可添加该固件文件。

## 相关参考

- [Goodix 驱动源码](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/input/touchscreen/goodix.c)
- [postmarketOS onclite 设备树](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/4351)
- [同类问题: Mi A2 Lite 触摸屏 (#2357)](https://gitlab.com/postmarketOS/pmaports/-/work_items/2357)
- [edt-ft5x06 probe defer RFC 补丁](https://lists.freedesktop.org/archives/dri-devel/2025-November/537600.html)
- 原始 DTB 备份: `/boot/sdm632-xiaomi-onclite.dtb.bak`

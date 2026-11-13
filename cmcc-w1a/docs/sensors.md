# CMCC-W1A 传感器与外设使用手册

日期：2026-10-28
适用：mainline 7.0 内核（`linux-mainline/`，`cmcc-w1a-7.0` 分支）+ `w1a.mode=display` initramfs / AsteroidOS

> 本文所有命令和数值均在手表上实测过（2026-10-28）。
> 设备节点编号（`iio:deviceN`、`eventN`、`i2c-N`）**跨启动会变化**，
> 请按名字查找，不要硬编码。

---

## 0. 状态总表

| 类别 | 器件 | 接口 | 驱动 | 状态 |
|---|---|---|---|---|
| 磁力计 | AK09915 | I2C QUP1 `0x0c` | `ak8975`（IIO） | ✅ |
| 气压计+温度 | BMP280 | I2C QUP1 `0x76` | `bmp280`（IIO） | ✅ |
| 加速度计 | LSM6DS3 | SPI QUP3 CS0，IRQ gpio96 | `st_lsm6dsx`（IIO） | ✅ |
| 陀螺仪 | LSM6DS3 | 同上 | `st_lsm6dsx`（IIO） | ✅ |
| 触摸屏 | FT3267 | I2C QUP5 `0x38`，IRQ gpio13 | `focaltech_ft3267`（input） | ✅ |
| 电量计 | CW2015 | I2C QUP4 `0x62` | `cw2015_battery`（power_supply/hwmon） | ✅ |
| 充电器 | PM8916 LBC | SPMI | `pm8916_lbc`（power_supply） | ✅ |
| 温度 | MSM8909 TSENS | — | `qcom_tsens`（thermal/hwmon） | ✅ |
| RTC | PM8909 | SPMI | `rtc-pm8xxx` | ✅ 读（写时间见第 10 节） |
| 电源键 | PM8909 PON | — | `pm8941_pwrkey`（input） | ✅ |
| 音量键 | TLMM gpio90 | — | `gpio-keys`（input） | ✅ |
| 耳机检测 | PM8909 | — | `pm8941` jack（input） | ✅ |
| 震动马达（输出） | PM8909 VIB | SPMI SID1 `0xc000` | `pm8xxx_vibrator`（evdev FF） | ✅ |
| 心率/PPG | PAH8011 | I2C QUP1 `0x15` | **无内核驱动** | ⚠️ 硬件在线，raw 可读 |
| GPS/GNSS | modem MSS | remoteproc + QRTR | `qcom_q6v5_mss` | ⚠️ 内核/固件已通，默认 skip |
| 环境光/接近 | — | — | — | ❌ 未发现 |
| PMIC BMS | PM8909 | SPMI | `pm8916_bms` | ❌ 已禁用（改用 CW2015） |

---

## 1. 通用约定

### 1.1 发现 IIO 设备

```sh
for d in /sys/bus/iio/devices/iio:device*; do
    echo "$d name=$(cat $d/name) of=$(readlink -f $d/of_node | sed 's#.*/##')"
done
```

典型输出（编号每次启动可能不同）：

```
/sys/bus/iio/devices/iio:device0 name=0-000c      of=magnetometer@c
/sys/bus/iio/devices/iio:device1 name=bmp280      of=barometer@76
/sys/bus/iio/devices/iio:device2 name=lsm6ds3_gyro of=accel@0
/sys/bus/iio/devices/iio:device3 name=lsm6ds3_accel of=accel@0
```

磁力计的 IIO 名字是 I2C 客户端名 `0-000c`，对应型号看：

```sh
cat /sys/bus/i2c/devices/0-000c/name    # ak09915
```

### 1.2 单位约定（IIO）

| 量 | `*_input` 单位 | `raw × scale` 单位 |
|---|---|---|
| 温度 | 毫摄氏度（m°C） | m°C |
| 气压 | kPa | kPa |
| 加速度 | m/s² | m/s² |
| 角速度 | rad/s | rad/s |
| 磁场 | 高斯（Gauss） | Gauss（×100 = µT） |

`*_input` 是内核换算后的物理量；`*_raw × *_scale` 是自己换算。
两者应当一致（标定值可能略有差异）。

### 1.3 权限

所有 sysfs 读取用 root 即可；写入（采样率、量程、阈值）需要 root。
触摸/按键/震动属于 `/dev/input/eventN`，需要 root 或 input 组权限。

---

## 2. 磁力计 AK09915

### 2.1 概览

- 位置：I2C QUP1（`/dev/i2c-0`）地址 `0x0c`
- DTS：`compatible = "asahi-kasei,ak09915"`
- 驱动：`drivers/iio/magnetometer/ak8975.c`，`CONFIG_AK8975=y`
  （AK09915 支持由提交 `082b15e` 加入）
- IIO 设备：`name = 0-000c`，DT 节点 `magnetometer@c`

### 2.2 属性

```sh
dev=/sys/bus/iio/devices/iio:device0      # 请按 name 查找
ls $dev
# in_magn_x_raw in_magn_y_raw in_magn_z_raw
# in_magn_x_scale in_magn_y_scale in_magn_z_scale
# in_mount_matrix name buffer0 scan_elements trigger
```

| 属性 | 含义 | 实测 |
|---|---|---|
| `in_magn_{x,y,z}_raw` | 各轴 ADC 原始值 | 2307 / 951 / -2204 |
| `in_magn_{x,y,z}_scale` | 高斯/LSB（每轴可能不同，ASA 校准） | 0.001500 |
| `in_mount_matrix` | 板级方向矩阵 | `1,0,0; 0,1,0; 0,0,1`（单位矩阵） |

### 2.3 读取与换算

```sh
dev=/sys/bus/iio/devices/iio:device0
for a in x y z; do
    raw=$(cat $dev/in_magn_${a}_raw)
    scl=$(cat $dev/in_magn_${a}_scale)
    awk -v r=$raw -v s=$scl -v a=$a \
        'BEGIN { g=r*s; printf "%s: %8.2f mG  (%8.2f uT)\n", a, g*1000, g*100 }'
done
```

- `磁场高斯 = raw × scale`
- `µT = Gauss × 100`
- 地磁场约 25–65 µT（0.25–0.65 G）；不带硬铁/软铁校准只能做相对变化判断。
  航向角需要先做椭球拟合校准，再 `atan2(-y, x)` 并做倾斜补偿。

### 2.4 采样说明

- 没有 `sampling_frequency` 属性，驱动内部以连续模式采集，直接读 `*_raw` 即最新值。
- `buffer0`/`scan_elements` 存在，但当前内核**没有注册任何 IIO trigger**
  （`/sys/bus/iio/devices/trigger*` 为空），所以走 buffered 连续采集前需要先接入
  trigger（例如 `iio-trig-hrtimer`，当前未启用）。简单应用直接轮询即可。

### 2.5 方向

`in_mount_matrix` 为单位矩阵：芯片轴 = 手表坐标轴，需要在应用层确认
“屏幕朝上/朝前”时哪个轴对应哪个方向（可结合加速度计确定）。

---

## 3. 气压计 BMP280

- 位置：I2C QUP1 `0x76`，DTS `compatible = "bosch,bmp280"`
- 驱动：`drivers/iio/pressure/`，`CONFIG_BMP280=y` + `CONFIG_BMP280_I2C=y`
- IIO 设备：`name = bmp280`，DT 节点 `barometer@76`

### 3.1 属性

| 属性 | 单位 | 实测 |
|---|---|---|
| `in_temp_input` | 毫摄氏度 | `36490.0` → 36.49 °C |
| `in_pressure_input` | kPa | `101.74` |
| `in_temp_raw` / `in_temp_scale` | m°C/LSB | `3644` / `10` |
| `in_pressure_raw` / `in_pressure_scale` | kPa/LSB | `26045808` / `0.000003906` |
| `in_pressure_oversampling_ratio` | — | `16`（可写） |
| `in_temp_oversampling_ratio` | — | `2`（可写） |

### 3.2 读取

```sh
dev=/sys/bus/iio/devices/iio:device1
awk -v t=$(cat $dev/in_temp_input) -v p=$(cat $dev/in_pressure_input) \
    'BEGIN { printf "T=%.2f C  P=%.2f kPa (%.1f hPa)\n", t/1000, p, p*10 }'
```

### 3.3 配置

```sh
# 气压过采样 16x（默认），可选 1/2/4/8/16
echo 16 > /sys/bus/iio/devices/iio:device1/in_pressure_oversampling_ratio
# 温度过采样
echo 2  > /sys/bus/iio/devices/iio:device1/in_temp_oversampling_ratio
```

海拔估算（标准海平面气压 1013.25 hPa）：

```
alt_m = 44330 * (1 - (P_hPa / 1013.25) ^ 0.1903)
```

---

## 4. 加速度计 LSM6DS3

- 位置：SPI QUP3（`0x78b7000`）CS0，IRQ **TLMM gpio96**
- DTS：`compatible = "st,lsm6ds3"`（提交 `b226f3e`）
- 驱动：`st_lsm6dsx`，`CONFIG_IIO_ST_LSM6DSX=y` + `_SPI=y`
- IIO 设备：`name = lsm6ds3_accel`，DT 节点 `accel@0`

### 4.1 属性

| 属性 | 说明 | 实测/默认 |
|---|---|---|
| `in_accel_{x,y,z}_raw` | 原始值 | -2172 / -4086 / -15520 |
| `in_accel_scale` | m/s²/LSB | `0.000598205`（±2 g） |
| `in_accel_scale_available` | 可选量程 | `0.000598205 0.001196411 0.002392822 0.004785645`（±2/4/8/16 g） |
| `sampling_frequency` | ODR（Hz，可写） | `12.5`；可选 `12.5 26 52 104 208 416` |
| `sampling_frequency_available` | 可选 ODR | 同上 |
| `mount_matrix` | 方向矩阵 | 单位矩阵 |
| `events/in_accel_{x,y,z}_thresh_either_{value,en}` | 阈值/唤醒事件 | 可写 |

### 4.2 读取与换算

```sh
dev=/sys/bus/iio/devices/iio:device3
for a in x y z; do
    printf "%s=%s " $a $(cat $dev/in_accel_${a}_raw)
done; echo
s=$(cat $dev/in_accel_scale)
awk -v x=$(cat $dev/in_accel_x_raw) -v y=$(cat $dev/in_accel_y_raw) \
    -v z=$(cat $dev/in_accel_z_raw) -v s=$s \
    'BEGIN { x*=s; y*=s; z*=s;
             printf "x=%.2f y=%.2f z=%.2f m/s^2  |a|=%.3f g\n",
                    x, y, z, sqrt(x*x+y*y+z*z)/9.80665 }'
```

静止时 `|a| ≈ 1 g`（约 9.81 m/s²）即为正常。

### 4.3 配置

```sh
dev=/sys/bus/iio/devices/iio:device3
echo 104 > $dev/sampling_frequency        # ODR 104 Hz
echo 0.001196411 > $dev/in_accel_scale    # 切到 ±4 g（写入 available 中的值）
```

### 4.4 事件（跌落/唤醒）

`events/` 下提供三轴阈值：

```sh
echo 1 > /sys/bus/iio/devices/iio:device3/events/in_accel_x_thresh_either_en
cat /sys/bus/iio/devices/iio:device3/events/in_accel_x_thresh_either_value
```

事件通过 IIO event 接口（`/dev/iio:deviceN` 的 read）上报；目前没有注册
trigger，做连续缓冲采集前需要先配 trigger。

---

## 5. 陀螺仪 LSM6DS3

- 与加速度计同一颗芯片，IIO 设备 `name = lsm6ds3_gyro`，DT 节点同为 `accel@0`
- 驱动/IRQ 同上

### 5.1 属性

| 属性 | 说明 | 实测/默认 |
|---|---|---|
| `in_anglvel_{x,y,z}_raw` | 原始值 | 22 / -471 / -251 |
| `in_anglvel_scale` | rad/s/LSB | `0.000152716` |
| `in_anglvel_scale_available` | 可选量程 | `0.000152716 0.000305432 0.000610865 0.001221729` |
| `sampling_frequency` | ODR（Hz，可写） | `12.5`，可选 12.5–416 |
| `mount_matrix` | 方向矩阵 | 单位矩阵 |

### 5.2 读取与换算

```sh
dev=/sys/bus/iio/devices/iio:device2
s=$(cat $dev/in_anglvel_scale)
awk -v x=$(cat $dev/in_anglvel_x_raw) -v y=$(cat $dev/in_anglvel_y_raw) \
    -v z=$(cat $dev/in_anglvel_z_raw) -v s=$s \
    'BEGIN { printf "x=%.3f y=%.3f z=%.3f rad/s  (%.1f/%.1f/%.1f deg/s)\n",
             x*s, y*s, z*s, x*s*57.2958, y*s*57.2958, z*s*57.2958 }'
```

静止时三条轴应接近 0；不为零的部分是零偏，需要在实际使用前做静态标定
（多次采样取平均后作为 bias 扣掉）。

### 5.3 配置

```sh
echo 104 > /sys/bus/iio/devices/iio:device2/sampling_frequency
echo 0.000305432 > /sys/bus/iio/devices/iio:device2/in_anglvel_scale
```

---

## 6. 触摸屏 FT3267（input）

- 位置：I2C QUP5（`0x78b9000`）`0x38`，IRQ gpio13，reset gpio12
- 驱动：`drivers/input/touchscreen/focaltech_ft3267.c`，`CONFIG_TOUCHSCREEN_FT3267=y`
- input 设备名字：`ft3267-touchscreen`（当前是 `/dev/input/event3`）
- 协议：多点触控 **Protocol B**（MT slots）

### 6.1 查找设备

```sh
for d in /sys/class/input/event*/device; do
    echo "${d%/device}: $(cat $d/name)"
done
```

### 6.2 能力

```sh
cat /sys/class/input/event3/device/capabilities/abs
cat /sys/class/input/event3/device/capabilities/key
```

支持的轴：`ABS_X/ABS_Y`、`ABS_PRESSURE`、`ABS_MT_SLOT`、
`ABS_MT_TOUCH_MAJOR`、`ABS_MT_POSITION_X/Y`、`ABS_MT_TRACKING_ID`；
坐标范围 `0..399`（`EVIOCGABS` 读取）。

### 6.3 读取示例（C）

```c
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    struct input_event ev;
    int fd = open("/dev/input/event3", O_RDONLY);   /* 按名字查找 */
    int x = 0, y = 0, touching = 0;

    while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type == EV_ABS) {
            if (ev.code == ABS_MT_POSITION_X) x = ev.value;
            if (ev.code == ABS_MT_POSITION_Y) y = ev.value;
            if (ev.code == ABS_MT_TRACKING_ID)
                touching = ev.value >= 0;
        } else if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
            if (touching)
                printf("touch %d,%d\n", x, y);
        }
    }
    return 0;
}
```

编译：

```sh
arm-linux-gnueabihf-gcc -O2 -static -o touch-read touch-read.c
```

> LVGL 不需要自己写这段：`lv_evdev_create(LV_INDEV_TYPE_POINTER, "/dev/input/event3")`
> 已经处理了协议 B、坐标范围和多点。见 `lvgl-demo/main.c`。

### 6.4 注意

- `/dev/input/mouseN`、`/dev/input/jsN` 不是这个设备，必须用 `eventN`。
- 不要用 `evtest`（镜像里没有）；上面的 20 行程序就够了。
- 触摸中断是 gpio13，若中断丢失先检查 `cat /proc/interrupts | grep ft3`。

---

## 7. 电量计 CW2015（power_supply）

- 位置：I2C QUP4 `0x62`，DTS `compatible = "cellwise,cw2015"`（提交 `ddaafe9`）
- 驱动：`drivers/power/supply/cw2015_battery.c`，`CONFIG_BATTERY_CW2015=y`
- 同时注册 power_supply 和 hwmon

### 7.1 power_supply 属性

设备：`/sys/class/power_supply/cw2015-battery/`

| 属性 | 单位 | 实测 |
|---|---|---|
| `voltage_now` | µV | 4285000（4.285 V） |
| `capacity` | % | 100 |
| `status` | — | Charging / Discharging / Full |
| `charge_now` | µAh | 400000 |
| `charge_full` | µAh | 400000 |
| `charge_full_design` | µAh | 400000 |
| `current_now` | µA | 0 |
| `present` | — | 1 |
| `technology` | — | Li-ion |
| `voltage_max_design` / `voltage_min_design` | µV | 4360000 / 3400000 |
| `time_to_empty_now` | s | 0（满电时） |

```sh
cat /sys/class/power_supply/cw2015-battery/capacity
cat /sys/class/power_supply/cw2015-battery/voltage_now
cat /sys/class/power_supply/cw2015-battery/status
```

### 7.2 hwmon 接口

```sh
for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat $h/name)" = cw2015_battery ] && echo $h
done
# in0_input   -> 电池电压（mV）
# curr1_input -> 电流（mA）
```

### 7.3 已知限制

- 没有官方 battery-profile blob，驱动使用芯片内 flash 的配置
  （启动日志：`No profile specified, continuing without profile`）。
- PMIC BMS 已禁用（提交 `34c9efa`），电池数据只有 CW2015 一个来源。
- `capacity` 是芯片内部算法的百分比，低电量段可能有跳变；
  需要更准时可向 CellWise 申请 profile 或自行做电压-电量标定。

---

## 8. 充电器 PM8916 LBC（power_supply）

- SPMI PM8909 linear charger，驱动 `CONFIG_CHARGER_PM8916_LBC=y`
- 设备：`/sys/class/power_supply/pm8916-lbc-chgr/`

| 属性 | 单位 | 实测 |
|---|---|---|
| `online` | — | 1（插 USB） |
| `type` | — | USB |
| `constant_charge_current` | µA | 630000（可写） |
| `constant_charge_voltage_max` | µV | 4300000 |
| `hwmon0` | — | 对应 `/sys/class/hwmon/hwmon0`（`pm8916_lbc_chgr`） |

```sh
cat /sys/class/power_supply/pm8916-lbc-chgr/online
cat /sys/class/power_supply/pm8916-lbc-chgr/type
```

该驱动没有 `status` 属性，充电状态请结合 CW2015 的 `status` 判断。
限流可在 `constant_charge_current` 调整（单位 µA，写入值会被驱动量化）。

---

## 9. 温度（TSENS）

- 驱动 `CONFIG_QCOM_TSENS=y`，5 个 zone

```sh
for z in /sys/class/thermal/thermal_zone*; do
    echo "$(cat $z/type): $(cat $z/temp)"
done
```

实测（m°C）：

| zone | 温度 |
|---|---|
| modem-thermal | 45000 → 45 °C |
| camera-thermal | 47000 → 47 °C |
| gpu-thermal | 43000 → 43 °C |
| cpu0-2-thermal | 53000 → 53 °C |
| cpu1-3-thermal | 53000 → 53 °C |

对应 hwmon：`hwmon2..hwmon6`（`modem_thermal`、`camera_thermal`、
`gpu_thermal`、`cpu0_2_thermal`、`cpu1_3_thermal`），读取方式相同。

---

## 10. RTC（PM8909）

- 驱动 `rtc-pm8xxx`，设备 `/dev/rtc0`，sysfs `/sys/class/rtc/rtc0/`
- 读时间：

```sh
cat /sys/class/rtc/rtc0/date
cat /sys/class/rtc/rtc0/time
cat /sys/class/rtc/rtc0/since_epoch
hwclock -r          # busybox 自带
```

当前设备显示 1970 年，是因为系统从未把时间写回 RTC。

**设置时间目前不可用**：内核需要 DT 里的 `allow-set-time` 才允许直接写
PMIC RTC。对应提交 `7598d94` 后来被 `73884ef` revert 了，所以现在：

```sh
date -s "2026-10-28 12:00:00"
hwclock -w          # → hwclock: ioctl(RTC_SET_TIME) failed: No such device
```

要恢复写能力，需要重新应用 `7598d94`（给 `rtc@6000` 加 label，并在 W1A DTS
上设置 `allow-set-time`），然后重编内核。

**闹钟/唤醒**：

```sh
echo +30 > /sys/class/rtc/rtc0/wakealarm   # 30 秒后触发
cat /sys/class/rtc/rtc0/wakealarm
echo 0 > /sys/class/rtc/rtc0/wakealarm     # 取消
```

（能否从 suspend 唤醒取决于 SoC 级 suspend 支持，见 backlog 第八节。）

---

## 11. 按键与耳机检测（input）

| 设备 | 名字 | 事件 | 说明 |
|---|---|---|---|
| `/dev/input/event1` | `pm8941_pwrkey` | `KEY_POWER` (116) | PMIC PON，长按关机/重启 |
| `/dev/input/event4` | `gpio-keys` | `KEY_VOLUMEUP` (115) | TLMM gpio90；按下为低电平 |
| `/dev/input/event2` | `cmcc-w1a Headset Jack` | `EV_SW` | bit2 `SW_HEADPHONE_INSERT`，bit4 `SW_MICROPHONE_INSERT` |

读取示例（按键）：

```c
struct input_event ev;
while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
    if (ev.type == EV_KEY)
        printf("key %u %s\n", ev.code, ev.value ? "down" : "up");
    else if (ev.type == EV_SW)
        printf("switch %u -> %d\n", ev.code, ev.value);
}
```

注意：event 编号按 `/sys/class/input/event*/device/name` 查找；
电源键的按下事件同时会触发 PMIC 中断，长按行为由 PMIC 硬件决定。

---

## 12. 震动马达（输出设备）

- PM8909 SPMI SID1 振动器 `0xc000`，驱动 `pm8xxx-vibrator.c`
- 用户态接口：evdev Force Feedback，只有 `FF_RUMBLE`
- 设备名 `pm8xxx_vib_ffmemless`（当前 `/dev/input/event0`）

### 12.1 命令行工具

`tools/w1a-vib`（源码 `tools/w1a-vib.c`）：

```sh
w1a-vib                  # 默认 200 强度 / 400 ms
w1a-vib -s 150 -t 150    # 轻、短
w1a-vib -s 254 -t 300    # 最强
w1a-vib -r 3 -t 100      # 连震 3 次
w1a-vib -l               # 列出输入设备
```

### 12.2 代码方式

```c
/* 初始化：上传一次效果 */
struct ff_effect eff = {
    .type = FF_RUMBLE, .id = -1,
    .replay.length = 40,              /* ms */
    .u.rumble.strong_magnitude = 254 << 8,
};
ioctl(fd, EVIOCSFF, &eff);
int id = eff.id;

/* 播放（value = 重复次数） */
struct input_event ev = { .type = EV_FF, .code = id, .value = 1 };
write(fd, &ev, sizeof(ev));
```

- 驱动映射：`speed = strong_magnitude >> 8`，再换算成 PMIC 驱动电压。
- **强度不要用 255**：驱动在 speed=255 时算出的档位是 32，与 5 位
  `VIB_VTG` 掩码（0x1F）相与为 0，马达不转。**254 是安全上限**。
- 震动期间保持 fd 打开；`close()` 会调用驱动回调停马达。
- LVGL 集成见 `lvgl-demo/main.c`（启动 `vib_init()`，按钮 `LV_EVENT_PRESSED`
  时 `vib_pulse()`）。

### 12.3 硬件证据

播放期间读 PMIC 寄存器（debugfs）：

```sh
mount -t debugfs none /sys/kernel/debug
grep "^c04[0-9a-f]:" /sys/kernel/debug/regmap/0-01/registers
# 播放中：c041 非零（驱动档位）、c046 = 0x80（使能）
# 停止后：c041 = 0、c046 = 0
```

---

## 13. 心率 PAH8011（硬件在线，驱动待做）

### 13.1 现状

- 位置：I2C QUP1 `0x15`，INT1 接 **TLMM gpio110**，POWERDN 引脚
- AP 侧没有内核驱动；stock 固件把驱动放在 SSC/ADSP 里
- 芯片可正常应答，Product ID 已确认

### 13.2 直接读寄存器

```sh
# 先确认 QUP1 对应哪个 /dev/i2c-N
for b in /sys/bus/i2c/devices/*; do
    echo "$b $(cat $b/name 2>/dev/null)"
done
# 0-000c ak09915  →  说明 QUP1 是 i2c-0

/usr/bin/i2cread /dev/i2c-0 0x15 0x00 1   # 0x11  Product_ID_LB
/usr/bin/i2cread /dev/i2c-0 0x15 0x01 1   # 0x80  Product_ID_HB → 0x8011
/usr/bin/i2cread /dev/i2c-0 0x15 0x02 1   # 0xB1  Version_ID
```

> `i2cread` 用法：`i2cread /dev/i2c-N ADDR REG LEN`。
> QUP 总线只能用 read-byte 方式，裸读会卡死总线（backlog 第七节）。

### 13.3 寄存器/数据格式

- `0x7F` 选择 Bank0/1/2/3/4
- Bank0：AE、LED DAC、ChA/B/C 分配（0x70–0x75）
- Bank1：TG_Enable(0x30)、INT_Type(0x35)、INT_Mode_Sel(0x36)、
  INT_Mask_Select(0x37)、帧周期、ADC 采样数、FIFO_RptNum(0x56/0x57)
- Bank2：0x1B 中断状态（bit0 FIFO、bit2 溢出、bit3 下溢）、0x25 样本数
- Bank3：FIFO 数据（从 0x00 突发读；32 位/样本，ChB/ChC 交织）
- Bank4：INT_Direction(0x15)、复位控制、PD_Mode(0x69)

官方参考实现：`github.com/PixartOpen/pah8011-qcom-adsp-driver`
（初始化数组 + touch/PPG 20Hz/200Hz 序列 + FIFO 处理）。
本地已有用户态验证工具 `asteroid/tmp/pahprobe.c`：
初始化、PPG 200Hz、TG 启动、FIFO 41 样本/报告均已验证。

### 13.4 内核驱动 TODO（配方已齐）

1. IIO 驱动 `pixart,pah8011`：probe 读 ID → 应用初始化数组 → start_tg/ppg →
   用 gpio110 中断触发 FIFO 读取
2. 暴露两个原始通道（ChB/ChC），HR 算法放用户态（厂商算法库闭源）
3. 供电：vdd/vddio 可用 l17/l6；LED 供电轨需在不插 USB 时确认

---

## 14. GPS / GNSS（不是 IIO 传感器）

- 硬件：modem（MSS）`mpss@4080000`，QMI LOC 服务运行在 modem DSP
- 内核：`CONFIG_QCOM_Q6V5_MSS=y`、`CONFIG_QRTR=y`、`CONFIG_QRTR_SMD=y`；
  DT `&mpss { status = "okay"; }`（提交 `4c8ae5a`）
- 固件：`w1a-init.sh` 从 modem 分区（`/dev/mmcblk0p1`，FAT16）
  复制 `modem.*` / `mba.mbn` 到 `/lib/firmware` 后 rebind remoteproc
- 当前镜像默认带 `/root/skip-mpss`，启动时跳过 modem：

```sh
cat /sys/class/remoteproc/remoteproc*/name
# 4080000.remoteproc  offline   ← modem（被 skip）
# a204000.remoteproc  running   ← ADSP/LPASS

rm -f /root/skip-mpss && reboot    # 启用 modem
```

- 用户态：`qmicli --loc-start`、`--loc-follow-nmea`、`--loc-follow-position-report`，
  NMEA 可喂给 `gpsd`。libqmi/gpsd 的 QMI 版本兼容性仍需实测。

---

## 15. 不支持的设备

| 设备 | 结论 |
|---|---|
| 环境光 / 接近传感器 | AP 总线扫描不到，stock 传感器注册表也没有条目；若存在则在 SSC/ADSP 后面，mainline 无法访问 |
| PMIC BMS（库仑计） | 已禁用（提交 `34c9efa`），避免与 CW2015 冲突；需先做电池 OCV 标定 |
| ADSP/SSC 传感器栈 | mainline 无；本机传感器均由 AP 直接驱动 |
| 摄像头 / NFC | 硬件未贴片（QUP2 空） |

---

## 16. 排查

| 现象 | 排查 |
|---|---|
| `iio:deviceN` 编号变了 | 按 `name` 或 `of_node` 查找，别写死编号 |
| 读 `*_input` 报 `ENODEV` | 驱动未绑定；`dmesg | grep -iE "ak099|bmp280|lsm6|ft3267"` |
| 加速度/陀螺没数据 | 检查 `ls /sys/bus/spi/devices/` 是否有 `spi0.0`；`dmesg | grep st_lsm6` |
| 触摸无事件 | 找对 eventN；`cat /proc/interrupts | grep ft3` |
| i2c 读卡住 | 只能用 `i2cread`（read-byte），不要裸读 |
| 震动无反应 | 强度别用 255；确认 `/sys/class/input/.../name` 是 `pm8xxx_vib_ffmemless` |
| 电量不更新 | 确认 CW2015 在 `i2c-2`；`dmesg | grep cw2015` |
| `hwclock -w` 失败 | RTC 写时间需要 DT `allow-set-time`（当前被 revert），见第 10 节 |

---

## 17. 一键快照脚本

```sh
#!/bin/sh
# sensor-dump：打印所有传感器当前值
dev() { for d in /sys/bus/iio/devices/iio:device*; do
        [ "$(cat $d/name 2>/dev/null)" = "$1" ] && echo $d; done; }

M=$(dev 0-000c)   # 磁力计；也可按 of_node=magnetometer@c 找
B=$(dev bmp280)
G=$(dev lsm6ds3_gyro)
A=$(dev lsm6ds3_accel)

echo "mag : $(cat $M/in_magn_x_raw) $(cat $M/in_magn_y_raw) $(cat $M/in_magn_z_raw) raw"
echo "baro: $(cat $B/in_temp_input) mC  $(cat $B/in_pressure_input) kPa"
echo "gyro: $(cat $G/in_anglvel_x_raw) $(cat $G/in_anglvel_y_raw) $(cat $G/in_anglvel_z_raw) raw"
echo "acc : $(cat $A/in_accel_x_raw) $(cat $A/in_accel_y_raw) $(cat $A/in_accel_z_raw) raw"
echo "bat : $(cat /sys/class/power_supply/cw2015-battery/capacity)%  $(cat /sys/class/power_supply/cw2015-battery/voltage_now) uV"
echo "chg : online=$(cat /sys/class/power_supply/pm8916-lbc-chgr/online)"
echo "temp: $(cat /sys/class/thermal/thermal_zone0/type)=$(cat /sys/class/thermal/thermal_zone0/temp)"
```

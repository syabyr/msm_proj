# CMCC W1A 外设移植 —— 遗留事项与后续实现方案

日期：2026-10-21（最后更新：2026-10-28）
分支：`cmcc-w1a-7.0`（内核树 `linux-mainline/`，构建输出 `ml-out/`）

> 传感器/外设的详细读写方法见 [`docs/sensors.md`](sensors.md)。

---

## 一、当前已验证状态（硬件实测）

| 外设 | 状态 | 说明 |
|---|---|---|
| 电源键 | ✅ | PMIC PON KPDPWR（需 `CONFIG_POWER_RESET_QCOM_PON=y`，见提交 29e3c18） |
| 音量键 | ✅ | TLMM gpio90，gpio-keys |
| 触摸屏 | ✅ | FocalTech FT3267，BLSP I2C5 (0x78b9000) @0x38，驱动 `focaltech_ft3267.c` |
| 磁力计 | ✅ | AK09915 @0x0c（QUP1），驱动 ak8975.c 已加 AK09915 ID（提交 082b15e） |
| 气压计 | ✅ | BMP280 @0x76（QUP1），`bosch,bmp280` |
| 加速度/陀螺 | ✅ | ST LSM6DS3，BLSP SPI3（QUP3，`0x78b7000`）CS0，IRQ gpio96，`st_lsm6dsx`（提交 b226f3e），IIO 实时数据 |
| 心率 | ❌ 驱动待做 | PixArt PAH8011 @QUP1 0x15，芯片在线、寄存器/PPG 序列已验证，IIO 驱动未写（见第三、五节） |
| 电量计 | ✅ | CW2015 @0x62（QUP4），PMIC BMS 已禁用（提交 34c9efa） |
| 震动马达 | ✅ | PM8909 VIB（SPMI SID1 `0xc000`），evdev `FF_RUMBLE`；工具 `tools/w1a-vib` |
| 温度 | ✅ | MSM8909 TSENS，5 个 thermal zone（modem/camera/gpu/cpu0-2/cpu1-3） |
| 音频录音 | ✅ | PM8909 WCD codec（SPMI **SID 1**）+ LPASS，Tertiary MI2S 采集 |
| WiFi | ✅ 驱动层 | wcn36xx（DXE），wlan0 已 up，WLAN 固件加载成功 |
| 蓝牙 | ✅ 驱动层 | btqcomsmd（WCNSS SMD），hci0 已注册 |
| GPS | ⚠️ 内核/固件已通 | `&mpss` 已启用、固件 staging + remoteproc + QRTR 已打通（提交 4c8ae5a）；本次启动由 `/root/skip-mpss` 跳过，用户态 libqmi/gpsd 待接（见第四节） |

---

## 二、音频播放（下一步最优先）

**现状**：录音已通；播放 PCM（`pcmC0D0p`，Primary MI2S）存在但未验证，需要配置 RX 侧 mux。

**已有工具**（位于 `asteroid/tmp/`，已放入 ramdisk `usr/bin/`）：
- `sndcap` —— 采集 + 峰值统计
- `sndmix` —— ALSA mixer 设置 / 枚举（`sndmix /dev/snd/controlC0 list`）

**录音需要的 mux**（已实测）：
```
sndmix /dev/snd/controlC0 "DEC1 MUX" 1   # ADC1
sndmix /dev/snd/controlC0 "CIC1 MUX" 0   # AMIC
```

**播放（已实测通过，2026-10-21）**：
```bash
sndmix /dev/snd/controlC0 "RX3 MIX1 INP1" 3   # RX1（关键！不是 RX3）
sndmix /dev/snd/controlC0 "SPK DAC Switch" 1
```
- 路径：LPASS Primary MI2S → 数字 codec `I2S RX1` → `RX3 MIX1` → `PDM_RX3` → PMIC `SPK DAC → SPK PA → SPK_OUT`
- 配置来源：stock `/system/etc/mixer_paths.xml`（"speaker": RX3 MIX1 INP1=RX1, SPK DAC Switch=1）
- 闭环验证：`sndplay` 播 1kHz 方波 + 同时 `sndcap` 采集，峰值从环境噪声 ~930 升到 ~4000
- 工具：`sndplay`（最小 ALSA 播放，`asteroid/tmp/sndplay.c`，已入 ramdisk）
- 注意：EAR 路径（`EAR_S`=Switch + RX1）会导致 DAI xrun，重试需重启；不要用

**已固化到启动流程（p15 实测）**：ramdisk 的 `/init` 在进入 display 模式/switch_root 之前执行：
```sh
/usr/bin/sndmix /dev/snd/controlC0 "RX3 MIX1 INP1" 3
/usr/bin/sndmix /dev/snd/controlC0 "SPK DAC Switch" 1
/usr/bin/sndmix /dev/snd/controlC0 "DEC1 MUX" 1
/usr/bin/sndmix /dev/snd/controlC0 "CIC1 MUX" 0
```
（先等待 `/dev/snd/controlC0` 出现；ALSA mixer 状态在内核中跨 switch_root 保留）。
验证：开机后只读读取四个控制项均正确，且直接 `sndplay`+`sndcap` 回环即有声（峰值 ~4000）。
**注意**：ramdisk 里的 `sndmix` 必须是带 `get` 子命令的新版本；旧版本会把 `get` 当作数字 0 执行写入，悄悄清空配置。
**仍待做**：进入 AsteroidOS 后由 UCM/PulseAudio 接管时的正式配置（当前是 initramfs 层）

**注意**：LPASS 的 periods 固定为 2、period_bytes 固定 24576；`HW_PARAMS` 前需先 `HW_REFINE` 并把结果回写（`sndcap.c` 里有现成实现）。

---

## 三、0x15 设备 —— 已确认：PixArt PAH8011 光学心率传感器

证据：stock 系统的 `/system/etc/sensors/sensor_def_qcomdev.conf`（已从 p21 只读挂载读取）：

```
# SSI SMGR Cfg 5: Heart Rate PAH8011 DRI
3606 1     #i2c_bus
3609 110   #gpio1          <- 中断线 TLMM gpio110
3611 90    #sensor_id      <- SNS_SMGR_ID_HEART_RATE
3612 0x15  #i2c_address    <- QUP1 上的 0x15
3613 0x23  #data_type1     <- 心率数据类型
```

同一文件的其它条目与实测完全吻合（AK0991x @0x0C、BMP280 @0x76），确认该配置就是 W1A 的注册表。
版本：驱动 `sns_dd_pah_8011.c` 编译在 **ADSP/modem 固件**（modem.b*）里，所以 AP 侧没有驱动/DT 节点。
寄存器指纹 `0x00=0x11` 即 PAH8011 的 part ID（数据手册已公开，见下）。
2026-10-28 在手表上复测：`0x00=0x11`、`0x01=0x80`、`0x02=0xB1`，芯片仍在线。

**寄存器资料（2026-10-22 补全）**：
- **PAH8011ES 数据手册是公开的**（PixArt，v1.1；已下载并提取到 `asteroid/tmp/pah8011-layout.txt`）
- 实测寄存器与手册默认值完全一致：`0x00=0x11 (Product_ID_LB)`、`0x01=0x80 (Product_ID_HB)` → **Product ID 0x8011**、`0x02=0xB1 (Version_ID)`
- 寄存器分组：写 `0x7F` 选择 Bank0/1/2/3/4；Bank3 = FIFO 数据（从 0x00 突发读）
  - Bank0：AE（自动曝光）各通道、LED DAC 范围、ChA/B/C LED/Pixel Assign（0x70-0x75）
  - Bank1：TG_Enable (0x30)、INT_Type (0x35)、INT_Mode_Sel (0x36)、INT_Mask_Select (0x37)、帧周期、ADC 采样数、ChX_Function (0x21/0x23/0x25)、FIFO_RptNum (0x56/0x57)、FIFO_AutoClearNum (0x58)
  - Bank4：INT_Direction (0x15)、Global_Reset_N (0x64)、TG_Reset_N (0x65)、Reg_Reset_N (0x66)、PD_Mode_EnH (0x69)
- 硬件：3 路 LED（2 绿 + 1 红外）、INT1 接 TLMM gpio110、POWERDN 引脚；供电 VDDM 3.1-3.6V / VDDA,VDDD 1.7-1.9V / VDDIO 1.62-3.6V / VDDAY 2.8V
- 心率算法：PixArt 的算法库闭源；但原始 PPG 数据可自行处理（峰值检测/开源算法），或用 Mbed 示例 main.cpp 作为初始化参考

**官方源码（2026-10-22 找到）**：`github.com/PixartOpen/pah8011-qcom-adsp-driver`（PixArt 官方，BSD 风格许可），本地在 `temp/pah8011-qcom-adsp-driver/`。关键内容：
- `sns_dd_pah_driver_8011_reg.h`：完整初始化序列 + touch/PPG 20Hz/PPG 200Hz 寄存器数组（bank0/4/5/1）
- `sns_dd_pah_driver_8011.c`：`_pah8011_start_tg()` / `_pah8011_start_ppg()` / `pah_task()`（FIFO 处理）
- FIFO 格式：每样本 32 位，双通道交织（ChB、ChC）；Bank2 0x1B = 中断状态（bit0=FIFO、bit2=溢出、bit3=下溢），Bank2 0x25 = 16 位样本数；Bank3 从 0x00 突发读 n*4 字节

**用户态验证已完成（pahprobe，`asteroid/tmp/pahprobe.c`）**：
- Product_ID 0x11/0x80 ✓，初始化数组 + PPG 200Hz 数组应用成功 ✓
- TG 启动序列（mask 0x37、TG 0x30=1、清 int、解 mask）✓
- FIFO 稳定按 41 样本/报告输出（= FIFO_RptNum 默认值），约 200Hz 双通道 ✓
- 读数很小（约 14–98）：手表插在 USB 线上时光学窗口被桌面/线材挡住，无法做手指遮挡测试，待不插线时验证

**内核驱动待做（配方已齐）**：
1. IIO 驱动 `pixart,pah8011`：probe 读 ID → 应用三组寄存器数组 → start_tg/ppg → IRQ(gpio110) 触发 pah_task 式 FIFO 读取
2. IIO 暴露两个原始通道（ChB/ChC）；HR 算法在用户态实现（官方算法库闭源）
3. 供电：vdd/vddio 可用 l17/l6（芯片已能响应）；LED 供电轨需在不插线时确认

---

## 四、GPS（modem + QMI LOC）

### 硬件与固件
- modem = MSS：`mpss@4080000`（`qcom,msm8909-mss-pil`），内存在 `mpss_mem`/`mba_mem`
- 固件在 **modem 分区**（`/dev/mmcblk0p1`，**FAT16**，目录 `image/`）：
  - `mba.mbn`（226KB）
  - `modem.mdt` + `modem.b00..b24`（合计约 35MB）

### 内核侧（已启用，提交 4c8ae5a）
1. `qcom_q6v5_mss` 已支持 `qcom,msm8909-mss-pil`（`drivers/remoteproc/qcom_q6v5_mss.c`）
2. QRTR over SMD：`net/qrtr/smd.c`（匹配 modem 的 `IPCRTR` rpmsg 通道）；`CONFIG_QRTR=y`、`CONFIG_QRTR_SMD=y`
3. DT：`&mpss { status = "okay"; }`（提交 4c8ae5a）
4. 固件路径：`w1a-init.sh` 把 modem 分区（FAT）里的
   `modem.*` / `mba.mbn` **复制**到 `/lib/firmware`，然后 rebind mpss remoteproc
   （复制而不是 symlink：remoteproc 在根文件系统就绪前会先 probe 一次）
5. 当前状态（2026-10-28）：本启动镜像默认带 `/root/skip-mpss`，init 打印
   `[modem] SKIP: /root/skip-mpss`，`4080000.remoteproc` 为 **offline**；
   删掉该文件重启即可启动 modem。副核 `a204000.remoteproc`（ADSP/LPASS）为 running。

### 用户态（开源方案）
- **libqmi**（LGPL-2.1+，freedesktop/ModemManager 项目）——已确认 1.35.2 含完整 LOC 服务
- `qmicli --loc-start`、`qmicli --loc-follow-nmea`、`qmicli --loc-follow-position-report`
- NMEA 可经 pty 喂给 **gpsd**（BSD）供上层使用
- AsteroidOS/Alpine 仓库有 libqmi 包；initramfs 内使用需静态交叉编译或从根文件系统切换后运行

### 风险
- 固件为 Android 7 时代 QMI 版本，LOC 定义可能与 libqmi 不完全吻合（QMI 一般向后兼容，需实测）
- modem 的 remoteproc 路径已在 mainline 打通（提交 4c8ae5a），但 LOC/QMI 服务尚未实测；
  当前镜像默认 `skip-mpss`，需要时删除 `/root/skip-mpss` 后重启
- 属于中等偏大工程，建议作为独立里程碑

---

## 五、加速度/陀螺/心率（已重新定位）

- **加速度 + 陀螺：已支持**。既不在 I2C、也不在 SSC 后面：stock 传感器注册表的
  `SPI_bus 0x1003` 对应 BLSP1 QUP3 SPI（`0x78b7000`），CS0，IRQ TLMM gpio96。
  `st,lsm6ds3` + `st_lsm6dsx`（提交 b226f3e），IIO 实时输出：
  `iio:device2 = lsm6ds3_gyro`、`iio:device3 = lsm6ds3_accel`。
- **心率：硬件已确认，驱动待做**。PAH8011 在 QUP1 0x15，AP 可直接访问；
  Product ID / 初始化数组 / PPG 200Hz FIFO 已用 `pahprobe` 验证（第三节）。
  内核 IIO 驱动仍是 TODO；心率算法需用户态实现。
- 结论：除心率外，W1A 的传感器都不依赖 ADSP/SSC 传感器栈。

---

## 六、其他遗留

1. **推送**：本地提交 `b237564`（BT 配置）尚未 push
2. **WiFi/BT 用户态**：需要 `wpa_supplicant`/`iwd`、`bluez`（切根后由发行版提供）；initramfs 内做连通性测试可临时加入 `iw`/`bluetoothctl`
3. **PMIC BMS**：待真正做电池 OCV 标定后，可重新启用 `&pm8909_bms`（当前为避免与 CW2015 冲突已禁用）
4. **CW2015**：无官方 battery-profile blob，使用芯片内 flash 配置；如需更准可向 CellWise 申请 profile
5. **总线占用现状**：QUP1 = AK09915/BMP280/PAH8011；QUP3 = LSM6DS3（SPI 模式）；
   QUP4 = CW2015；QUP5 = FT3267；QUP2 无设备（stock camera/NFC 未贴片）；
   QUP6 保持禁用。未发现环境光/接近传感器（AP 总线和 stock 注册表均无条目）。
6. **固件归档**：WCNSS 固件/NV 未入 git（厂商专有），本地保存在 `asteroid/tmp/fw/` 与 ramdisk 构建产物；重装环境时需从 eMMC 重新提取：
   - 挂载 `mmcblk0p21`(system, ext4)、`p22`(persist, ext4)、`p1`(modem, vfat)
   - 取 `p1/image/wcnss.*`、`p22/WCNSS_qcom_wlan_nv.bin`、`p21/etc/firmware/wlan/prima/WCNSS_cfg.dat`
7. **音频时钟**：`gcc-msm8909` 的 ULTAUDIO 时钟是从 8916 移植的精简版（去掉外部 MCLK 父源）；如后续接外部 codec 需补回

---

## 七、关键参考

### 设备树要点
- 音频 codec 在 **SPMI SID 1** 的第二个 PMIC 上（`pmic@1` → `pm8909_codec`），不在 SID 0
- 播放链路 Primary MI2S，采集链路 **Tertiary MI2S**（Primary 在 LPASS 驱动里只有 playback）
- CDC PDM 引脚：gpio59..64，function `cdc_pdm0`
- 传感器：磁力计/气压计/心率在 QUP1，加速度+陀螺在 QUP3（SPI），电量计 QUP4，触摸 QUP5

### 构建与测试
```bash
cd linux-mainline
make O=../ml-out ARCH=arm CROSS_COMPILE=arm-none-eabi- -j$(nproc) zImage dtbs
cd ..
W1A_OUT=asteroid-mainline-w1a-XXX.img W1A_CMD='w1a.no_dsi_pa w1a.mode=display log_buf_len=8M ' bash tools/build-boot-img-nord.sh
fastboot boot asteroid-mainline-w1a-XXX.img
ssh root@192.168.2.1        # usbnet 192.168.2.1
```

### 坑位记录
- 手表重启后 USB 偶尔枚举成 `05c6:9091`（诊断模式），重新插拔 USB 线即可恢复 fastboot
- `ssh root@... 'reboot -f'` 可正常重启
- 裸 I2C 读（不带寄存器写前缀）会把 QUP 总线卡死，只能使用 read-byte 模式（`i2cdetect`/`i2cread` 已按此实现）
- ramdisk 为 tmpfs，每次启动需重新推送临时工具（i2cdetect/i2cread/sndcap/sndmix 已固化进 ramdisk 源）

---

## 八、低功耗（2026-10-21 已验证 CPU 侧）

**已启用并实测（提交 a8f0ac8，镜像 p12）：**
- `CONFIG_QCOM_SPM`、`CONFIG_ARM_QCOM_SPM_CPUIDLE` → cpuidle 出现 `cpu-sleep-0`（Qualcomm SPC 独立电源坍缩），空闲时大部分驻留在此状态
- `CONFIG_QCOM_CLK_APCS_MSM8916` → 提供 `<&apcs>` CPU 时钟，否则 `cpufreq-dt` 永久 defer
- `CONFIG_ARM_QCOM_CPUFREQ_NVMEM` → DVFS 生效：200/400/533/800/998/1094 MHz，schedutil 调度，频率随负载变化

**仍未做：**
1. 深度休眠：`/sys/power/state` 只有 `freeze mem`（s2idle），无 deep suspend；尚无 SoC 级 suspend（RPM/SPM 协同）
2. 显示功耗：MDP3 驱动永久持有 pm_runtime 引用，面板/背光常亮；需面板关屏 + runtime PM + 熄屏策略
3. WiFi/BT 低功耗模式（WCNSS 常开）
4. 手表式待机（熄屏 + 深睡 + 按键/RTC 唤醒）需要以上全部完成

---

## 九、持久化安装（w1a-persist，2026-10-22 实施）

**引导链**：
```
stock aboot (p4) → boot 分区里的 lk2nd (p20 @0)
  → lk2nd 扫描 ext2 分区，找到 p23 的 /extlinux/extlinux.conf
  → 启动 zImage + initramfs + DTB（cmdline: console=tty0 log_buf_len=8M panic=5 w1a.no_dsi_pa lk2nd.pass-ramoops=zap）
  → init 挂载 p33（直接根文件系统）→ 挂 p1 固件 → wcnss rebind → switch_root → AsteroidOS
```

**分区分配**：

| 分区 | 内容 | 说明 |
|---|---|---|
| p4 aboot | stock aboot | 不动 |
| p20 boot | lk2nd | 不动（烧写会变砖） |
| **p23 cache (64MB)** | **ext2**：/extlinux/{extlinux.conf,vmlinuz,initramfs.gz,dtbs/} | lk2nd extlinux 自动启动 |
| **p33 userdata (1.94GB)** | **根文件系统**（asteroidos.ext4 直接 dd 到分区起始） | init 检测 /etc/os-release 后直接作为 root |
| p1 modem (FAT) | wcnss/modem/mba 固件 | init 挂载到 /firmware |
| p22 persist | WCNSS NV | init 复制到 /lib/firmware/wlan/prima |
| p21 system (1.3GB) | stock Android | 保留（可回退） |

**备份**（`asteroid/backup/`）：
- p4-aboot.img (1M)、p20-boot.img (32M)、p1-modem.img (64M)、p22-persist.img (20M)、p21-system.img (1.3G)

**更新内核/initramfs**：重新生成 p23 的 ext2 镜像并写入（见下方命令），或直接在运行中的系统里挂载 p23 替换文件。

**恢复/回退**：
1. 若 extlinux 启动失败：lk2nd 停在 fastboot（或按住音量键进菜单），可 `fastboot boot asteroid-mainline-w1a-p15.img` 回到旧的 initramfs 测试镜像。
2. 恢复 stock Android 引导：把备份的 p20-boot.img 写回 p20（`dd`）即可；p21/p22/p1 未改动。
3. 重写 p23 镜像的构建命令：
   ```bash
   mkdir -p root/extlinux/dtbs
   cp ml-out/arch/arm/boot/zImage root/extlinux/vmlinuz
   cp ml-out/arch/arm/boot/dts/qcom/qcom-msm8909-cmcc-w1a.dtb root/extlinux/dtbs/
   cp tmp/ramdisk17.gz root/extlinux/initramfs.gz
   cat > root/extlinux/extlinux.conf <<CONF
   default w1a
   label w1a
     linux /vmlinuz
     initrd /initramfs.gz
     fdt /dtbs/qcom-msm8909-cmcc-w1a.dtb
     append console=tty0 log_buf_len=8M panic=5 w1a.no_dsi_pa lk2nd.pass-ramoops=zap
   CONF
   mke2fs -t ext2 -d root -F -L w1a-extlinux p23.img 64M
   ssh root@192.168.2.1 'dd of=/dev/mmcblk0p23 bs=1M' < p23.img
   ```
   **注意**：lk2nd 的 extlinux 只支持 ext2（无 extent），不能格式化为 ext4。

**写根文件系统**：
```bash
ssh root@192.168.2.1 'dd of=/dev/mmcblk0p33 bs=4M' < asteroidos.ext4
```

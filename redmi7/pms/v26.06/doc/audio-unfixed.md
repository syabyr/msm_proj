# PMS 26.06 — AW87329 扬声器功放调试报告 (未修复)

Xiaomi Redmi 7 (onclite), kernel 7.0.9-msm8953, postmarketOS 26.06.

## 状态: 未修复

**扬声器和听筒均无声音输出** — 经过完整的 I2C 寄存器配置 (kspk/drcv 两种模式), GPIO 复位, DAPM 通路验证后, AW87329 芯片仍无音频输出。

## 硬件架构

```
MSM8953 SoC
├── QDSP6 DSP (数字音频处理)
│   └── APR/SMD → ADSP firmware 通信
├── Primary MI2S (I2S 音频总线)
│   └── I2S RX3 → PDM_RX3 (数字codec通路)
├── WCD Analog Codec (PM8916-compatible, SPMI)
│   ├── SPK DAC ← PDM_RX3 (PDM_RX3 同时连接到 SPK DAC 和 LINEOUT DAC)
│   ├── SPK PA  → SPK_OUT (模拟输出, 连接 AW87329 INP)
│   └── HPHL/R DAC ← RX1/RX2 MIX1 (耳机通路)
└── AW87329 Smart PA (I2C @ 0x58 on i2c-7af5000)
    ├── INP: 连接到 WCD SPK_OUT (推测)
    ├── OUT: 底部扬声器 (kspk) 或 顶部听筒 (drcv/abrcv)
    ├── GPIO 139: Reset/Mode pin
    ├── 3 种工作模式: kspk (扬声器), drcv (听筒), abrcv (听筒备选)
    └── Charge Pump (CPOVP/CPP): 内部升压, 需外部电容
```

## AW87329 芯片详情

### 确认信息
- **芯片型号**: AW87329 (通过 I2C CHIPID reg 0x00 验证 → 0x39)
- **I2C 地址**: 0x58
- **I2C 总线**: i2c-7af5000 (BLSP5 QUP I2C)
- **Reset GPIO**: GPIO 139 (tlmm pin 139)
- **固件文件** (Android): `aw87329_kspk.bin`, `aw87329_drcv.bin`, `aw87329_abrcv.bin`

### 寄存器表 (0x00–0x0A)

| 寄存器 | 名称 | kspk (扬声器) | drcv (听筒) | abrcv (听筒备选) |
|--------|------|---------------|-------------|-------------------|
| 0x00 | CHIPID | 0x39 (只读) | 0x39 (只读) | 0x39 (只读) |
| 0x01 | SYSCTRL | 0x0E | 0x0A | 0x0A |
| 0x02 | MODECTRL | 0xA3 | 0xAB | 0xAF |
| 0x03 | CPOVP | 0x06 | 0x06 | 0x06 |
| 0x04 | CPP | 0x05 | 0x05 | 0x05 |
| 0x05 | GAIN | 0x10 | 0x00 | 0x00 |
| 0x06 | AGC3_PO | 0x07 | 0x0F | 0x0F |
| 0x07 | AGC3 | 0x52 | 0x52 | 0x52 |
| 0x08 | AGC2_PO | 0x06 | 0x09 | 0x09 |
| 0x09 | AGC2 | 0x08 | 0x08 | 0x08 |
| 0x0A | AGC1 | 0x96 | 0x97 | 0x97 |

关键寄存器解释:
- **SYSCTRL bit 3**: 0 = disable, 1 = enable (写入时先清 bit3 配置, 再置位使能)
- **SYSCTRL=0x08**: 完全禁用 (chip disable)
- **MODECTRL bit 7**: 模式选择 (0xA3=kspk, 0xAB=drcv, 0xAF=abrcv)
- **GAIN=0x10 (kspk)**: 16dB gain; **GAIN=0x00 (drcv/abrcv)**: 0dB (听筒音量低)

**注意**: kspk 默认 GAIN 在 Android kernel 中是 0x10 (16dB), 但在 mainline aw8738.c 测试中使用 0x1F (31dB, max), 差别在 GAIN 寄存器。

### 下游 (Android) 驱动关键代码

来自 `aw87329_audio.c` (v1.1.1):

```c
// hw_on: GPIO=0, msleep(2), GPIO=1, msleep(2)
// hw_off: GPIO=0, msleep(2)

// 写入流程 (以 kspk 为例):
i2c_write(SYSCTRL, kspk_val[SYSCTRL] & 0xF7);   // 禁能 bit3
i2c_write(MODECTRL, kspk_val[MODECTRL]);
i2c_write(CPOVP,    kspk_val[CPOVP]);
i2c_write(CPP,      kspk_val[CPP]);
i2c_write(GAIN,     kspk_val[GAIN]);
i2c_write(AGC3_PO,  kspk_val[AGC3_PO]);
i2c_write(AGC3,     kspk_val[AGC3]);
i2c_write(AGC2_PO,  kspk_val[AGC2_PO]);
i2c_write(AGC2,     kspk_val[AGC2]);
i2c_write(AGC1,     kspk_val[AGC1]);
i2c_write(SYSCTRL,  kspk_val[SYSCTRL]);           // 使能 (bit3=1)
```

Android machine driver (`msm8952.c`) 通过 `ext_kspk_amp`/`ext_drcv_amp` mixer 控件触发:
```c
static int ext_kspk_amp_put(...) {
    if (ucontrol->value.integer.value[0])
        aw87329_audio_kspk();    // → I2C 写入 kspk 寄存器
    else
        aw87329_audio_off();     // → SYSCTRL=0x08 (disable)
}
```

Android DTS 中的配置:
```dts
i2c@7af5000 {
    aw87329@58 {
        compatible = "awinic,aw87329_pa";
        reg = <0x58>;
        reset-gpio = <&tlmm 139 0>;
    };
};
```

**重要**: Android 的 `qcom,msm-spk-ext-pa` GPIO 在 DTS 中是**注释掉的** — 扬声器功放完全由 AW87329 驱动通过 I2C 控制, 不使用 GPIO pulse 模式。

## 测试过程

### 测试 1: kspk (扬声器) 模式 — 2026-07-12

**修改**: `aw8738.c` 通过 `awinic,i2c-bus` phandle 获取 I2C 总线, probe 时创建 `i2c_new_dummy_device`, POST_PMU 时写入 kspk 寄存器。

**验证结果**:
- dmesg: `AW87329 chipid=0x39` (芯片 ID 正确)
- dmesg: `AW87329 KSPK mode: SYSCTRL=0x0e MODECTRL=0xa3 GAIN=0x1f` (寄存器写入 + 读回确认)
- GPIO 139: 播放时 out high, 空闲时 out low (正确)
- DAPM: `Speaker Amp DRV=On`, `Speaker Amp OUT=On`, `Speaker Amp IN=On`, `SPK DAC=On`, `SPK PA=On`
- DAPM: `HPHL DAC=Off`, `EAR PA=Off` (耳机/听筒正确关闭)

**结果**: 无声音。

### 测试 2: drcv (听筒) 模式 — 2026-07-12

**修改**: 将 `aw87329_write_regs(aw, kspk_regs)` 改为 `aw87329_write_regs(aw, drcv_regs)`。

**验证结果**:
- dmesg: `AW87329 DRCV mode: SYSCTRL=0x0a MODECTRL=0xab GAIN=0x1f` (寄存器写入 + 读回确认)
- GPIO 139: 播放时 out high
- 所有 DAPM widget 状态正确

**结果**: 无声音 (包括听筒也无声音)。

### 测试 3: 回退到 GPIO 脉冲模式 (仅 AW8738 兼容模式)

DTS 中不配置 `awinic,i2c-bus`, 驱动回退到 GPIO 脉冲协议 (mode=5 → 5个脉冲控制增益)。

**结果**: 顶部听筒有声音 (之前 PMS 25.12 的行为), 但不是底部扬声器。

## 已验证的正确状态

| 检查项 | 状态 | 详情 |
|--------|------|------|
| AW87329 CHIPID | ✓ 0x39 | I2C 通信正常 |
| I2C 寄存器写入 | ✓ 正确 | 写入后读回确认 SYSCTRL/MODECTRL/GAIN |
| GPIO 139 复位时序 | ✓ 正确 | 0→2ms→1→2ms, 播放时为 HIGH |
| WCD SPK DAC | ✓ On | DAPM widget 状态确认 |
| WCD SPK PA | ✓ On | DAPM widget 状态确认 |
| Speaker Amp DRV | ✓ On | 驱动 DAPM event 被调用 |
| 耳机通路 | ✓ 关闭 | HPHL DAC=Off, EAR PA=Off |
| MultiMedia3 路由 | ✓ 正确 | PRI_MI2S_RX Audio Mixer MultiMedia3=On |
| RX3 MIX1 路由 | ✓ 正确 | RX3 MIX1 INP1=RX3 (PCM 数据进入 PDM_RX3) |

## 未解决的问题

### 核心问题: 所有软件状态正确, 但硬件无输出

两种 I2C 模式 (kspk/drcv) 都测试过, 寄存器值经验证正确, 但:
- **扬声器 (底部)**: 完全无声音
- **听筒 (顶部)**: I2C 模式下也无声音 (但 GPIO 脉冲模式下有声音)

### 可能的根本原因

**1. 模拟音频输入未连接 (可能性最高)**

AW87329 的 INP 引脚需要从 WCD codec 的 SPK_OUT 获取模拟音频信号。如果:
- WCD SPK_OUT 引脚和 AW87329 INP 之间的 PCB 走线有断开
- AW87329 需要不同的输入源 (可能不是 SPK_OUT)
- 需要额外的模拟开关或路由 (可能在 PMIC 或 codec 内部)

**2. 电荷泵 (Charge Pump) 未工作**

AW87329 内部有升压电路 (CPOVP/CPP 寄存器控制), 需要外部电容。如果:
- 外部电容未正确充电 (需要足够的使能时间)
- CPOVP/CPP 寄存器值与硬件不匹配
- 需要在播放开始前有额外的延迟等待电荷泵稳定

注意: kspk 和 drcv 使用相同的 CPOVP/CPP 值 (0x06/0x05), 所以如果电荷泵是问题, 两种模式应该都受影响 (实际情况确实如此)。

**3. WCD SPK_OUT 路径未完全启用**

mainline `msm8916-wcd-analog.c` 驱动可能缺少某些 Android 下游驱动中的寄存器配置:
- `SPK_OUT` 需要特定的 analog switch 或 mux 设置
- Android 的 `msm8952.c` machine driver 调用 `aw87329_audio_kspk()` 之前可能配置了额外的 codec 寄存器
- PDM_RX3 → SPK DAC 的连接虽然 widget 显示 On, 但可能需要额外的系数或使能位

**4. 电源轨未启用**

AW87329 需要:
- VBAT (电池电压, 通常是 3.7-4.2V, 经过电荷泵升压至 ~8V)
- VDD (数字/模拟电源)
- 某些电源可能由 PM8953/PMI632 的 regulator 控制, 需要在 DTS 中明确引用

**5. pinctrl 配置**

GPIO 139 当前的 pinctrl 配置可能不完整:
- 可能需要配置为特定功能 (not just GPIO)
- 驱动强度可能需要调整
- 可能需要 pull-up/pull-down 配置

**6. I2C 时序/竞争条件**

虽然 I2C 通信正常 (CHIPID readback 成功), 但:
- 在 POST_PMU 中 GPIO 复位和 I2C 写入之间可能需要更长的延迟
- Android 驱动在 `cfg_init` 中每次都做 `hw_on → read_chipid → hw_off` 循环确认
- 当前 mainline 驱动在 hw_on 后直接写配置, 可能缺少某些必要的等待

**7. AW87329 需要 firmware 加载**

Android 驱动支持从固件文件加载配置 (`.bin` 文件):
```
aw87329_kspk.bin, aw87329_drcv.bin, aw87329_abrcv.bin
```
这些固件文件可能包含与硬件匹配的特定校准数据或寄存器序列。如果芯片在出厂时需要先加载特定配置才能工作, 使用默认寄存器可能不够。

## 下游 vs Mainline 对比

| 特性 | Android 下游 | Mainline (aw8738.c) |
|------|-------------|---------------------|
| 驱动 | aw87329_audio.c (v1.1.1) | aw8738.c (GPIO pulse + I2C mod) |
| I2C 控制 | 原生 I2C client | i2c_new_dummy_device |
| 模式切换 | mixer 控件 ext_kspk_amp/ext_drcv_amp | POST_PMU event (固定模式) |
| Firmware | 支持 .bin 文件加载 | 不支持 |
| 初始化 | hw_on → read_chipid → cfg_init → hw_off | POST_PMU 时 hw_on → write_regs |
| Machine driver | msm8952.c (专有) | apq8016_sbc.c (通用) |
| 音频路由 | HAL mixer_paths.xml 控制 | DTS audio-routing |
| SPK DAC 使能 | 未知 (可能在 HAL/mixer 中) | SPK DAC Switch (amixer numid=73) |

## 调试命令参考

### 验证 I2C 通信 (需要先卸载 aw8738 驱动)
```bash
# 检查 I2C 总线
i2cdetect -y 2       # i2c-7af5000 在设备上通常是 bus 2
# 0x58 应显示为 UU (被驱动占用) 或 58 (空闲)

# 读取芯片 ID (需要 i2cget)
i2cget -y 2 0x58 0x00  # 应返回 0x39
```

### 启用扬声器通路 (每次重启后)
```bash
amixer cset numid=59 "RX3"    # RX3 MIX1 INP1 = RX3 (数字codec: I2S RX3 → PDM_RX3)
amixer cset numid=152 on      # PRI_MI2S_RX Audio Mixer MultiMedia3 = On
amixer cset numid=73 on       # SPK DAC Switch = On
amixer cset numid=52 on       # Speaker Switch = On
```

### 验证 DAPM 状态
```bash
# AW8738 驱动的 DAPM widget
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker\ Amp\ IN | head -1
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker\ Amp\ DRV | head -1
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/audio-amplifier/dapm/Speaker\ Amp\ OUT | head -1

# WCD codec 的 DAPM widget
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK\ DAC | head -1
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK\ PA | head -1
sudo cat /sys/kernel/debug/asoc/xiaomi-onclite/200f000.spmi:pmic@1:audio-codec@f000/dapm/SPK_OUT | head -1

# 确认 GPIO 139 状态
sudo cat /sys/kernel/debug/gpio | grep gpio139
# 播放时: out high
# 空闲时: out low
```

### 测试播放
```bash
# hw:0,2 = MultiMedia3 (PDM_RX3, 扬声器通路)
speaker-test -t sine -f 440 -l 3 -D hw:0,2

# hw:0,0 = MultiMedia1 (RX1, 耳机通路)
speaker-test -t sine -f 440 -l 3 -D hw:0,0
```

### 模块编译 (Docker + clang 22.1.8)
```bash
docker run --rm --network host \
  -v $(pwd)/linux-7.0.9:/build -w /build \
  fedora:latest sh -c "
    dnf install -y clang lld llvm make flex bison bc elfutils-libelf-devel openssl-devel
    make LLVM=1 ARCH=arm64 olddefconfig
    make LLVM=1 ARCH=arm64 modules_prepare
    make LLVM=1 ARCH=arm64 KBUILD_MODPOST_WARN=1 M=sound/soc/codecs modules
  "
```

## 下一步建议

1. **分析 WCD codec SPK_OUT 模拟路径** — 用示波器测量 SPK_OUT 引脚在播放时是否有模拟波形, 确认 WCD codec 端是否有输出
2. **检查 AW87329 电源** — 确认 VBAT/VDD 供电是否正常, 测量电荷泵输出电压
3. **获取 AW87329 datasheet** — 确认硬件连接和上电时序要求
4. **从 Android 内核提取固件文件** — 尝试加载 `aw87329_kspk.bin` 到芯片
5. **用逻辑分析仪捕获 I2C 通信** — 对比 Android 和 mainline 的 I2C 时序差异
6. **回退到 GPIO 脉冲模式 + kspk firmware** — 如果 AW87329 支持 GPIO 脉冲模式配置 kspk (而不只是增益), 可能不需要 I2C

## 相关文件

```
msm_proj/redmi7/pms/v26.06/
├── dts/sdm632-xiaomi-onclite-v3-sensors-fixed.dts    ← 恢复后的 DTS (GPIO 脉冲模式)
├── dts/sdm632-xiaomi-onclite-v3-sensors-fixed.dtb    ← 恢复后的 DTB
├── sdm632-xiaomi-onclite-audio-unfixed.dts            ← I2C 测试版 DTS (存档)
├── sdm632-xiaomi-onclite-audio-unfixed.dtb            ← I2C 测试版 DTB (存档)
├── linux-7.0.9/sound/soc/codecs/aw8738.c              ← 修改后的驱动 (当前为 drcv 模式)
├── modules/snd-soc-aw8738.ko                          ← 编译后的驱动模块
└── doc/
    ├── audio-unfixed.md                               ← 本文档
    └── sensors-fixed.md                               ← 传感器/其他修复文档

backup-20260711/android_kernel_xiaomi_onclite/
├── techpack/audio/asoc/codecs/aw87329_audio.c         ← Android 下游 AW87329 驱动
├── techpack/audio/asoc/msm8952.c                       ← Android machine driver
└── arch/arm64/boot/dts/qcom/msm8953-audio.dtsi        ← Android 音频 DTSI

audio/
├── audio.md                                           ← PMS 25.12 时代的音频调试笔记
├── sdm632-xiaomi-onclite-audio-fix.dtb                ← 25.12 的音频 DTB
└── sdm632-xiaomi-onclite-speaker-fix.dtb              ← 25.12 的扬声器 DTB
```

## 时间线

| 日期 | 事件 |
|------|------|
| 2025-06 (PMS 25.12) | 首次尝试 GPIO 脉冲模式 — 顶部听筒有声音, 底部扬声器无声音 |
| 2025-07-11 | 从 Android kernel source 确认 GPIO 139 + I2C 0x58 |
| 2026-07-12 | 修改 aw8738.c 添加 I2C 支持, 测试 kspk 模式 — 无声音 |
| 2026-07-12 | 修改为 drcv 模式测试 — 听筒也无声音 (I2C 模式下) |
| 2026-07-12 | 回退到 GPIO 脉冲模式, 归档 I2C 测试版本, 生成本文档 |

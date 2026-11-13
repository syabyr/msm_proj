# CMCC W1A (MSM8909)：音频与 modem 冲突诊断记录

日期：2026-10-24
相关文档：[w1a-bringup-2026-10-24.md](w1a-bringup-2026-10-24.md)（环境、GPS、WiFi 等）

---

## 1. 现象

- `/root/0.wav`（24 kHz mono）与 `/root/032.mp3` 无法播放，"没有声音"。
- `aplay` 进程不报错，PCM 状态是 `RUNNING`，但：
  - `hw_ptr` 停在 **2**，`appl_ptr` 已到 24576；
  - LPASS 播放 DMA 寄存器 `RDMACURR` 冻结在 `DMABASE + 4`；
  - `/proc/interrupts` 中 LPASS 中断 **51 一直为 0**。
- 同一块板子上，**采集通路（tertiary I2S / WRDMA）正常**，中断能正常增长。

## 2. 两个内核

| 内核 | 说明 | 音频 |
|---|---|---|
| `7.0.0-gb916d7069411 #66` | 旧内核，`mybays@viscus` 编译 | ✅ 正常 |
| `7.0.0-g4c8ae5a0d030 #4` | 新内核，c8ae5a 提交 | ❌ 无声 |

`b916d7069411..4c8ae5a0d030` 的差异只有三处，全部与 modem/GPS 有关：

- DTS：`&mpss { status = "okay"; }`
- defconfig：`CONFIG_QRTR=m → =y`
- defconfig：`CONFIG_QRTR_SMD=m → =y`
- defconfig：新增 `CONFIG_QCOM_Q6V5_MSS=y`

旧内核没有 `QCOM_Q6V5_MSS`，板子上只有 `wcnss`（WiFi）一个 remoteproc；新内核会由 `/etc/w1a-init.sh` 第 3c 段启动 `4080000.remoteproc`（MSS/modem）。

## 3. 诊断过程

### 3.1 全量基线采集

为做旧/新内核严格对比，编写并运行 `/root/capture_baseline.sh`（主机副本见
`/mnt/2T/temp/build/cmcc-w1a/baseline/capture_baseline.sh`），采集内容包括：

- 内核标识、cmdline、config.gz、`/etc/w1a-init.sh`、dmesg、devicetree tar；
- ALSA cards/pcm/info、`amixer contents`、remoteproc 列表与状态；
- 全部 LPASS/音频时钟的 `clk_rate/enable_count/prepare_count/parent`；
- LPASS（`7708000.audio-controller-lpass_cpu`）与 WCD 数字 codec（`771c000.audio-codec`）的完整寄存器；
- 空闲、播放 `/root/0.wav`、采集（hw:0,1）三个时刻的快照，含 DAPM 状态与 `/proc/interrupts`。

产物（主机）：

```
/mnt/2T/temp/build/cmcc-w1a/baseline/
├── old-gb916d706/base-old.tar.gz      # 旧内核（正常）
├── new-4c8ae5a/base-new.tar.gz        # 新内核（modem 运行，无声）
└── capture_baseline.sh
```

设备上另存：`/root/base-old.tar.gz`、`/root/capture_baseline.sh`。

### 3.2 对比结果

| 项目 | 旧内核（正常） | 新内核（无声） | 是否不同 |
|---|---|---|---|
| I2SCTL primary (0x1000) | `0x4600` | `0x4600` | 否 |
| RDMACTL (0x8400) | `0x81f` | `0x81f` | 否 |
| DMABASE / DMABUFF | `9b890000` / `0x2fff` | `9b890000` / `0x2fff` | 否 |
| RDMACURR (0x840c) | 持续前进 | **冻结在 base+4** | **是** |
| LPASS IRQ 51（播放时） | 546 → 569 | **0** | **是** |
| pri_i2s 时钟 | 1536000，parent xo-board，enable | 完全相同 | 否 |
| digcodec / ahbfabric 时钟 | 9.6 MHz / 99.99 MHz | 完全相同 | 否 |
| DAPM speaker 路径 | 26 个 widget On | 完全相同 | 否 |
| 数字 codec 播放相关寄存器 | `0x00C=0x33` 等 | 完全相同 | 否 |
| 整体 LPASS 寄存器 diff | — | 仅 DMA 指针等 4 处 | 否（配置一致） |

结论：软件可见的 LPASS 配置、时钟、DAPM、codec 状态全部一致，只有**播放 DMA 不消耗**。
说明主 MI2S TX 的位时钟实际上没有运行，而这在软件可见配置里看不出来。

### 3.3 A/B 决定性实验

modem 由 `/etc/w1a-init.sh` 第 3c 段从用户态启动（驱动 `auto_boot` 关闭），因此可以不改内核做 A/B。

在 `/etc/w1a-init.sh` 的 3c 段开头加入可撤销开关：

```sh
(
    if [ -e /root/skip-mpss ]; then echo "[modem] SKIP: /root/skip-mpss" > /tmp/modem.log; exit 0; fi
    LOG=/tmp/modem.log
    ...
```

创建 `/root/skip-mpss` 后重启（同一新内核 `g4c8ae5a0d030`），modem 保持 `offline`：

```
=== t=3s   hw_ptr 143360   RDMACURR 9b8917c0   IRQ 51 = 14
=== t=6s   hw_ptr 322296   IRQ 51 = 26
播放正常，有声音。
```

**结论：同一内核，modem 不启动时音频完全正常；modem 启动即无声。modem（MSS）是直接原因。**

## 4. 根因（mainline 已知限制）

这不是内核 bug，也不是配置错误，而是 mainline 对 MSM8916/8909「直接控制 LPASS」音频方案的固有限制。

上游 commit `38192dc36f1f`（Stephan Gerhold，`ASoC: dt-bindings: qcom: Document qcom,msm8916-qdsp6-sndcard compatible`）原文：

> There are two possible audio setups on MSM8916/APQ8016: Normally the audio
> is routed through the audio/modem DSP (covered by the qdsp6 driver). During
> upstreaming for the DragonBoard 410c it was decided to bypass it and
> instead talk directly to the audio controller using the "lpass" driver.
>
> Bypassing the DSP gives more control about the audio configuration but limits
> the functionality: For example, routing audio through the audio/modem DSP is
> strictly required for voice call audio. Also, without the special changes in
> the DB410c firmware other MSM8916 devices can only use the bypass as long as
> the modem DSP is not started. Otherwise, the firmware will assume control of
> the LPASS hardware block and audio is no longer functional.

即：**modem DSP 一启动，固件就接管 LPASS 硬件块**，直接控制 LPASS 的播放通路随即失效。
这与实测吻合：启动后 LPASS 寄存器读回仍是我们写入的值，但 DMA 不再被消费、中断不再产生。

### 4.1 为什么不能两者兼得

正解是把音频改走 QDSP6（`q6afe`/`q6asm`/`q6routing` + ADSP remoteproc）。但本机：

- `qcom-msm8909.dtsi` 中**没有 ADSP / q6afe 节点**（对比 arm64 的 `msm8916.dtsi` 有）；
- 固件分区 `mmcblk0p1 image/` 只有 `modem.*`、`mba.mbn`、`venus.*` 等，**没有 `adsp.mdt`**；
- 因此 QDSP6 音频路径无法实现。

结论：在这套硬件+固件上，**音频与 modem（GPS/定位）互斥，只能按每次开机二选一**。

## 5. 当前方案（已实施并验证）

默认**音频优先**：开机不启动 modem。

| 文件/路径 | 作用 |
|---|---|
| `/root/skip-mpss` | 标记文件；存在则 `/etc/w1a-init.sh` 3c 段直接跳过 |
| `/etc/w1a-init.sh` | 3c 段开头增加标记检查（其余逻辑不变） |
| `/root/w1a-init.sh.orig` | 改动前原始脚本备份 |

切换方式（改标记后重启）：

```sh
# 音频优先（当前默认）
touch /root/skip-mpss && reboot

# 定位优先（GPS/QRTR 可用，声音失效直到下次重启）
rm /root/skip-mpss && reboot
```

验证（音频优先，重启后）：

```
kernel: 7.0.0-g4c8ae5a0d030
skip-mpss: present
mpss: offline
pcm0p state: RUNNING, hw_ptr 94584 持续推进
```

注意：即使 modem 运行，**采集**通路仍然工作；受影响的是播放（primary MI2S TX）。

## 6. 调试工具与危险操作

设备上留下了 `/root/rdmmio`（静态链接 ARM 独立程序，用 mmap 读 `/dev/mem` 的 32 位寄存器）：

```sh
/root/rdmmio 0x7709000     # 读 LPASS primary I2SCTL（播放时 0x4600）
```

**危险操作（已实测导致板子宕机/重启，勿再执行）：**

1. `cat /sys/kernel/debug/regmap/1800000.clock-controller/registers`
   —— GCC 时钟控制器全量 dump，读到保留偏移（如偏移 0）会卡死总线，`panic=5` 触发重启。
2. `/dev/mem` 读 GCC 偏移 0（`0x1800000`）同样会卡死；音频时钟寄存器在时钟门控时读取也会挂起。
3. `echo stop > /sys/class/remoteproc/remoteproc0/state`（MSS）曾直接导致板子重启。

需要时钟状态时，只用 `/sys/kernel/debug/clk/<name>/...`。

## 7. 快速判断清单

```sh
# 当前是否音频优先
[ -e /root/skip-mpss ] && echo "audio-first" || echo "modem-first"
for r in /sys/class/remoteproc/remoteproc*; do
    echo "$r $(cat $r/name) $(cat $r/state)"
done

# 播放检查：正常时 hw_ptr 应持续增长、IRQ 51 递增
timeout 6 aplay -q /root/0.wav >/dev/null 2>&1 &
sleep 3
grep -E 'hw_ptr|state' /proc/asound/card0/pcm0p/sub0/status
grep -E '^\s*51:' /proc/interrupts
pkill -x aplay
```

- `hw_ptr` 冻在 2、IRQ 51 为 0 → modem 正在运行，属预期现象；
- 需要声音：`touch /root/skip-mpss && reboot`。

## 8. 本次变更清单

| 位置 | 变更 |
|---|---|
| 设备 `/etc/w1a-init.sh` | 3c 段开头新增 `/root/skip-mpss` 标记检查（跳过 modem 启动） |
| 设备 `/root/skip-mpss` | 新增标记文件（音频优先） |
| 设备 `/root/w1a-init.sh.orig` | 原始启动脚本备份 |
| 设备 `/root/rdmmio` | 新增：静态 ARM MMIO 读取工具（调试用） |
| 主机 `baseline/` | 新增：capture_baseline.sh + 旧/新内核基线快照 |
| 内核源码 | 无修改 |

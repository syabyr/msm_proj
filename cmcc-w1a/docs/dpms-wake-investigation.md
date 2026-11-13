# W1A DPMS 熄屏/唤醒问题 — 完整调查记录

> 结论（2026-10-30）：`echo 4 > /sys/class/graphics/fb0/blank`（DPMS off）后
> `echo 0`（唤醒）面板可以正常回来、亮度保持不变。
> 最终方案不是"修复 DSI 重建"，而是**永不拆除 DSI 链路**（keepalive），并在
> blank 时撤掉 MDP3 的帧流源头（autorefresh）。
>
> 代码分支：`cmcc-w1a-7.0`
> 关键提交：`f457841fd2e2`（v50 keepalive）、`fb4ba6975617`（v51 stability）
> 可用镜像：用 `asteroid/tools/build-boot-img.sh` 从当前 `ml-out` 重新构建
> 一个 p33 正常启动镜像（原 `keepalive2.img` 已清理）

---

## 1. 问题背景

### 硬件
- **CMCC W1A 儿童定位手表**：Qualcomm MSM8909（APQ8009W），512MB RAM
- 屏幕：Raydium **RM67162** 400×400 圆形 AMOLED，**MIPI DSI command mode**
  （单 lane、RGB888、DCS 0x51 调亮度、TE 由面板引脚输出）
- 关键供电：l2 = DSI PHY 1.2V、l6/l17 = 面板与 IO 轨（always-on）

### 软件栈
- **lk2nd**（第二级引导，装在 p20 前 512KB）负责初始化 DSI/PHY/PLL/面板，
  并留下一条**正在运行的**显示链路（带 autorefresh 自刷新）
- **mainline Linux 7.0-wip（msm8916-mainline fork，分支 cmcc-w1a-7.0）**：
  - 自研 `mdp3` KMS 驱动（`drivers/gpu/drm/msm/disp/mdp3/`）
  - 复用 msm DSI host/PHY 驱动，加 W1A 专属 quirk
  - 自研 `panel-raydium-rm67162` 驱动
- 启动方式：lk2nd → boot p20（+512KB 处的 boot.img）→ 内核 → Alpine rootfs（p33）

### 初始症状（用户原始 power.log）
```
echo 4 > /sys/class/graphics/fb0/blank   # DPMS off —— 屏幕熄灭，看似正常
echo 0 > /sys/class/graphics/fb0/blank   # 唤醒 —— 屏幕不亮
```
日志中的典型错误：
- `WARNING: unbalanced disables for l6`
- `msm_dsi_phy 1ac8300.phy: Failed to disable vddio: -EIO`
- `msm_dsi_phy 1ac8300.phy: Runtime PM usage count underflow!`
- `gcc_mdss_byte0_clk status stuck at 'off'`
- `msm_dsi_host_power_on: failed to enable link clocks. ret=-16`
- `dsi_cmds2buf_tx: cmd dma tx failed ... ret=-110`
- 用户另外注意到：唤醒后**亮度会回到 255**

---

## 2. 排查使用的取证手段（都是本次建立并沿用的）

| 手段 | 位置 | 作用/教训 |
|---|---|---|
| `MDP3DBG` 一次性启动 dump | `mdp3_kms.c` `mdp3_dsi_raw_dump()` | DSI(35项)/PHY/PLL/GCC RCG 寄存器快照，boot 与运行态逐字段 diff |
| `MDP3STEP` 分步健康快照 | `dsi_host.c` `w1a_step()` | power_on 每个步骤打印 ctrl/st0/fifo/clkst/intc，定位"从哪一步开始变坏" |
| vblank 超时 dump | `mdp3_crtc.c` | DMA_P、CB4、tear-check、stream 寄存器现场 |
| **ramoops 邮箱 `w1a_mb()`** | `mdp3_kms.c` | 直写 ramoops 区（`__va`），绕过 printk/console_lock；`fastboot oem ramoops raw` 取回 |
| 面板 DCS 读回 | `panel-raydium-rm67162.c` | `mipi_dsi_dcs_read(0x0A)` 验证链路双向是否真的通 |
| `clk_summary` | debugfs | 安全读取时钟树频率/使能状态 |

**重要教训（已写入长期记忆）**
1. **绝不在 `TRIG_DMA` 写入后立刻读 DSI 寄存器** —— v24 因此总线挂死、整机复位。
2. **绝不用 userspace `/dev/mem` 探测 DSI/RAM 地址** —— 外部 abort 直接复位
   （见 `mempeek-unmapped-pa-crash`）。
3. `pr_flush()` 不可出现在 commit 路径（会把 console_lock 拖成死锁，历史 m2l 事故）。
4. arm32 的 `ioremap`/`memremap` 都拒绝 RAM 页 —— 需要 `__va()`。

---

## 3. 完整排查时间线（v1 → v51，约 40 个构建）

### 阶段 A：修掉"修复过程本身引入的错误"（v1–v10）
| 版本 | 改动 | 结果 / 教训 |
|---|---|---|
| v1 | 关 inherit → 全量重编程 | 黑屏；每帧 100k/s DSI ERROR 中断风暴 |
| v3–v4 | 屏蔽 DSI ERROR 中断组；FIFO 空闲位过滤 | 风暴消失；仍黑屏 |
| v7–v9 | pixel clk set_rate 容忍；PLL raw 种子回写；post-enable 重写 postdiv3/vreg | 链路打通(无 -110)，仍黑屏 |
| v10 | **hybrid**：仅 boot 用 inherit，首次 power_off 后走全量路径 | 系统不再挂死、DPMS off 干净 |

### 阶段 B：理解"为什么唤醒失败"（v11–v49）
逐个排除（每个都有硬证据）：

1. **时钟树/PLL 种子/分频** — 寄存器 dump 与 lk2nd 逐位一致 → 排除
2. **GEM vmap 生命周期** — 修了 shrinker 回收导致的 NULL Oops（v13）
3. **IRQ 传递丢失** — 改为 lk2nd 式轮询（INTR_CTRL 预清 + poll），仍失败 → 排除
4. **CMA 高地址 DMA 限制** — 改用 lk2nd 保留低端页 `0x8f68f000`，仍失败 → 排除
5. **SMMU 翻译失效** — **v34 抓到 CB4 translation fault, far=0x8f68f000**
   → 确认需要 identity map（v37 修好，命令全部通过）
6. **interrupt/poll 竞态** — `local_irq_save` 串行化（v27），boot 稳定但 wake 仍失败
7. **sw_reset 破坏 PHY 训练** — 跳过（v30）又恢复（v46），两者都试过
8. **force-HS clock lane**（stock 8909 errata）— v31/v39 移植，无效
9. **MDP3 CGC/VBIF/tear-check 重初始化** — v49，无效
10. **SMMU 域 reattach**（stock 每批命令 attach/detach）— v37 加上、v41 移除，均无效

### 阶段 C：找到真正的两个症结（v50–v51）

**观察 1（v40）**：唤醒后面板 DCS 读回 `pm=0x9c`（Display On + Normal Mode +
Sleep Out + Booster On），与 boot 完全相同 → **面板本身完全正常**。

**观察 2（v44/v45）**：TE 在流（SYNC_PRIMARY_LINE 中断 ~25/s）、所有 DSI 寄存器
与 boot 一致（ctrl=0x115, dma_ctrl=0x14000000, mdpctl2=0x00010006,
str0ctl=0x04b10039, str0tot=0x01900190, trig=0x04）、CB4 无 fault、MDSS 时钟
（vco 602.7M / byte 37.67M / pclk 12.56M / vsync 19.2M）全部正常。

**但** `dsi_status0=0x115`（bit2 = CMD_MODE_MDP_BUSY 卡死），`DMA_P_DONE`
（MDP3 INTR bit14）永不触发 → 面板没有帧数据 → 显示默认白色。

> 也就是说：**任何一次真实的 DSI 断电重建之后，command-mode 的 MDP 帧流都会
> 永久卡死**，即使所有可读状态都与工作态一致。这是本次调查最核心的结论。

**观察 3（v50 第 3 轮）**：在 keepalive 下，连续多轮循环后偶尔仍会卡死 ——
因为 blank 期间面板停止扫描（无 TE），而 MDP3 的 autorefresh 仍在向 DSI 推帧，
cmd-mode MDP stream 会挂在"等 TE"上永久 busy。

---

## 4. 最终方案

### 4.1 DSI keepalive（v50）
`msm_dsi_host_power_off()` 在 `w1a_dsi_keepalive`（默认开）时直接返回：
不做 `dsi_ctrl_disable`、不关 link clocks、不动 regulator、不关 PHY。
DPMS off 只让**面板**进入 display-off + sleep-in（由 panel bridge 完成）。
`dsi_manager.c` 的 `w1a_maybe_phy_disable()` 同样跳过 PHY 关闭。

- 代码：`drivers/gpu/drm/msm/dsi/dsi_host.c:3489`，标志 `w1a_dsi_keepalive`（:144）
- 开关：cmdline `w1a.no_dsi_keepalive` 恢复完整拆除

**代价**：DPMS off 期间 DSI/PHY/PLL 仍耗电（省电主要来自面板本身），
换来的是唤醒可靠。

### 4.2 blank 时撤掉帧流（v51）
`mdp3_crtc_atomic_disable()`（在 modeset disable 阶段、面板睡眠**之前**）：
```c
mdp3_write(kms, REG_MDP3_AUTOREFRESH_CONFIG_P, 0);
kms->autorefresh_taken = false;
kms->commit_count = 0;
```
唤醒后由已有的 m4b "2nd-commit takeover" 逻辑自动重新接管（`mdp3_flush_commit`）。

- 代码：`drivers/gpu/drm/msm/disp/mdp3/mdp3_crtc.c:159`

### 4.3 支撑性修复（keepalive 能工作的前提）

**TX buffer（SMMU）**
- boot 阶段用 GEM/IOVA（继承模式已验证）
- 首次 power_off 之后切换到 **lk2nd 保留页 `0x08f68f000`**（DTS `/memreserve/`），
  用 `memremap`→`__va` 映射（arm32 memremap 拒绝 RAM 页）
- 切换点（`msm_dsi_host_power_on` 内）立刻
  `msm_iommu_map_page_ident()` 把它 identity-map 进 `priv->kms->vm`
  （v34 CB4 fault 的修复；放在下一个 commit 做就晚了 —— v36 教训）
- 每次 trigger 前 `dma_sync_single_for_device(..., DMA_TO_DEVICE)`
  （`__va` 是 cached 映射；GEM 路径是 WC 所以 boot 不需要）

**命令 TX 协议（移植 lk2nd）**
- `INT_CTRL` 预清 `0x03030303` + `local_irq_save` 下轮询 bit0（不依赖 GIC IRQ）
- `LANE_CTRL` bit28（CLKLN_HS_FORCE_REQUEST）在 trigger 前置位、完成后释放
  （stock 8909 errata，`mdss_dsi_cmd_start/stop_hs_clk_lane`）

**PLL**
- probe 时捕获 lk2nd 原始种子（refclk/postdiv1/postdiv3/vreg/sdm0-4/cal）
- `set_rate`、`sw_reset` 之后、post-enable 三处原样回写
  （mainline 计算出的种子锁定在"功能不同"的配置上 → HS 通路死）
- pixel clk `set_rate` 失败可容忍（command mode 不用 pclk）

**时钟**
- link clocks 在命令之间保持使能（clkhold），且**不额外取 enable 引用计数**
  （计数不平衡会让 clk 框架与硬件失同步，power cycle 后 vco prepare 被跳过）

**面板驱动**
- 亮度保存/恢复：init 序列用 `ctx->brightness` 替代硬编码 `0x51 0xff`
  （修复"唤醒后亮度回 255"）
- enable/disable 前各发一条**牺牲命令**（页选 0xFE→0x00），吸收重上电后
  第一笔 DMA 的时钟未稳窗口
- `disable` 的 DCS 超时不再向上返回错误（否则 `panel->enabled` 卡住，
  下一次 enable 被 "Skipping enable of already enabled panel" 跳过）

---

## 5. 验证结果（v51 实机）

```
连续 5 次 DPMS off/on：
enabled count:  2 → 3 → 4 → 5     （每次唤醒 panel enable 成功）
cmd timeouts:   0
vblank timeouts:0
brightness:     40（设置值，循环后保持）
```

亮度接口：
```sh
cat  /sys/class/backlight/1ac8000.dsi.0/brightness      # 0-255
echo 40 > /sys/class/backlight/1ac8000.dsi.0/brightness
```

---

## 6. 已知限制 / 后续工作

1. **DPMS off 不省 DSI 的电**：keepalive 的代价。真正的省电需要 MDP3/DSI
   的完整 runtime PM 支持，且必须先解决"重建后 MDP stream 卡死"的根因。
2. **重建卡死的根因仍未定位到寄存器级**：所有可读寄存器与工作态一致，
   说明差异在不可读的模拟/内部状态（PHY 训练、DSI 内部状态机）。
   若将来要修，建议方向：
   - 用逻辑分析仪观察唤醒后 DSI 总线上是否有 HS 数据
   - 对比 stock 3.18 内核（`android-msm-skipjack-3.18-oreo-wear-dr`，
     已下载到 `docs/mdss_dsi_host.c` 等）在 suspend/resume 时的完整序列
3. **偶发命令超时**：多轮循环后仍可能出现单条命令 -110（自愈），
   属于牺牲命令窗口的残留抖动，不影响点亮。
4. `w1a.no_dsi_keepalive` 可回到完整拆除路径（用于将来调试）。

---

## 7. 复现 / 测试手册

```sh
# 从当前 ml-out 构建 p33 正常启动镜像（原 keepalive2.img 已清理）
cd /home/mybays/develop/build/cmcc-w1a
W1A_OUT=w1a-p33.img bash asteroid/tools/build-boot-img.sh
# 启动镜像（p20 = 512KB lk2nd + OS 镜像，偏移 512K）
fastboot boot w1a-p33.img
# 或写入 p20：
dd if=w1a-p33.img of=/dev/mmcblk0p20 bs=512 seek=1024 conv=fsync

# 验证
echo 40 > /sys/class/backlight/1ac8000.dsi.0/brightness
for i in 1 2 3; do
  echo 4 > /sys/class/graphics/fb0/blank; sleep 2
  echo 0 > /sys/class/graphics/fb0/blank; sleep 2
  cat /sys/class/backlight/1ac8000.dsi.0/brightness   # 应保持 40
done
dmesg | grep -cE "cmd dma tx failed|vblank timeout"  # 应为 0

# 取证（崩溃/卡死时）
fastboot oem ramoops raw && fastboot get_staged ramoops.bin
strings ramoops.bin | grep -a W1AMB        # 邮箱记录
```

内核心跳/panic 取证：`mdp3_kms.c` 的 `w1a_watchdog_start()`（4s 停滞 panic），
panic 时 `panic_console_replay` 会把整个 ringbuffer 写进 ramoops。

---

## 8. 相关文件

| 文件 | 说明 |
|---|---|
| `linux-mainline/drivers/gpu/drm/msm/disp/mdp3/` | MDP3 KMS（mdp3_kms.c/crtc.c/plane.c/dsi_encoder.c/hwio.h） |
| `linux-mainline/drivers/gpu/drm/msm/dsi/dsi_host.c` | DSI host + 全部 W1A quirk |
| `linux-mainline/drivers/gpu/drm/msm/dsi/phy/dsi_phy_28nm.c` | PHY/PLL + raw 种子逻辑 |
| `linux-mainline/drivers/gpu/drm/panel/panel-raydium-rm67162.c` | 面板驱动 |
| `linux-mainline/drivers/gpu/drm/msm/msm_iommu.c` | identity map helper |
| `docs/mdss_dsi_host.c` 等 | stock 3.18 参考源码（skipjack 分支） |
| `docs/power.log` | 用户最初的问题日志 |

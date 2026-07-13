# Xiaomi Redmi 7 (onclite) @ 192.168.1.159 — GPS 诊断文档

## 设备信息

| 项目 | 值 |
|------|-----|
| 设备型号 | Xiaomi Redmi 7 (onclite) |
| SoC | Qualcomm MSM8953 (SDM632) |
| OS | postmarketOS |
| 内核 | 6.17.7-msm8953 |
| ModemManager | 1.24.2 |
| libqmi | 1.36.0 |

## 问题现象

GPS 不工作，geoclue 无法获取位置。

## 根因

**没有插入 SIM 卡，导致 Modem DSP 无法完成初始化，QMI 服务（包括 GPS/GNSS）均不可用。**

### 故障链路

```
无 SIM 卡
  → ModemManager 无法初始化 modem (modem0: sim-missing)
    → modem 进入 "failed" 状态
      → QMI 服务 (DMS/NAS/PDS/LOC) 未在 QRTR 总线上注册
        → GNSS 定位服务不可用
          → geoclue 无 GPS 数据源
            → GPS 不可用
```

## 诊断过程

### 1. Modem DSP 状态

三个 remoteproc 实例均正常运行：
```
remoteproc0: 4080000.remoteproc (Modem/MPSS) → running
remoteproc1: a204000.remoteproc (WCNSS/WiFi/BT) → running
remoteproc2: adsp → running
```

Modem 固件加载时序：
```
[25.545586] remoteproc0: 4080000.remoteproc is available
[27.993083] remoteproc0: powering up 4080000.remoteproc
[27.997445] remoteproc0: Booting fw image mba.mbn
[28.143749] MBA booted without debug policy, loading mpss
[29.004704] remoteproc0: remote processor 4080000.remoteproc is now up
```

### 2. ModemManager 日志 (journalctl)

```
[qrtr0/probe] probe step: QMI
[qrtr0/probe] probe step: done                          ← QRTR 链路建立成功
[device qcom-soc] creating modem with plugin 'qcom-soc' and '2' ports
[modem0] unhandled QMI radio interface '9'             ← 部分 QMI 接口可用
[modem0] state changed (unknown -> locked)              ← 需要 SIM 解锁
modem couldn't be initialized: Couldn't check unlock status:
  QMI operation failed: GW primary session index unknown  ← QMI DMS 拒绝
[modem0] state changed (locked -> failed)               ← 最终失败
error initializing: Modem in failed state: sim-missing   ← 根因：无 SIM
```

### 3. UIM (SIM 卡) 选择服务

```
msm-modem-uim-selection:
  error: node with id 0 not found in QRTR bus          ← UIM 节点不存在
  error: couldn't create client for the 'uim' service:
    QMI protocol error (3): 'Internal'                  ← UIM QMI 服务拒绝
```

### 4. QMI 服务可用性

所有 qmicli 命令均失败：
```
qmicli -d qrtr://0 --dms-get-capabilities
  → Error receiving data: Connection reset by peer
  → error: couldn't open the QmiDevice: endpoint hangup
```

无 QRTR 节点在 sysfs 中暴露，表明 QMI 命名服务未正常注册任何服务。

### 5. GPS 软件栈

| 组件 | 状态 |
|------|------|
| rmtfs | 运行中 |
| qrtr / qrtr_smd | 模块已加载 |
| ModemManager | 运行中，modem 处于 failed 状态 |
| qmi-proxy | 运行中 |
| geoclue | 运行中，配置为 `modem-gps=true` |
| gpsd | **未安装** |
| gnss-share | **未安装** |
| qmicli | 已安装 (qmi-utils) |

### 6. geoclue 配置 (`/etc/geoclue/geoclue.conf`)

geoclue 已启用所有位置源：
```
[3g]          enable=true       ← 需要 ModemManager modem 可用
[modem-gps]   enable=true       ← 需要 ModemManager GNSS 功能
[network-nmea] enable=true      ← 需要外部 NMEA 源
[wifi]        enable=true       ← 需要 WiFi 扫描
```

但所有这些源的底层都依赖 ModemManager 的 modem 对象正常工作。

## 修复方案

### 方案 A：插入 SIM 卡（根本解决）

插入一张有效的 SIM 卡后，modem 可完成初始化，QMI 服务会正常注册，GPS/GNSS 功能随之可用。

预期流程：
1. 插入 SIM → modem 解锁 → QMI DMS/NAS/PDS/LOC 服务就绪
2. ModemManager 创建完整 modem 对象
3. geoclue 通过 ModemManager 的 Location 接口获取 GPS 数据

### 方案 B：软件层面尝试强制启用 GPS（可能无效）

即使没有 SIM，可以尝试让 modem 固件加载更多 QMI 服务：

```bash
# 1. 重启 ModemManager（清除 failed 状态）
sudo systemctl restart ModemManager

# 2. 重新初始化 modem
sudo qmicli -d qrtr://0 --dms-set-operating-mode=online

# 3. 检查 LOC 服务是否出现
sudo qmicli -d qrtr://0 --loc-start --client-no-release-cid
```

**注意**：方案 B 大概率无效，因为 modem 固件在无法访问 UIM 时不会启动完整的 QMI 服务栈。

### 方案 C：使用外部 GPS 源

如果有外部 GPS 接收器：
```bash
sudo apk add gpsd
sudo systemctl enable --now gpsd
```
geoclue 的 `[network-nmea]` 可接收外部 NMEA 数据。

### 方案 D：仅使用 WiFi 定位

当前 geoclue 已配置 `[wifi] enable=true`，但需要配置 Mozilla Location Service (MLS) 密钥：
```bash
sudo apk add geoclue-mls
# 编辑 /etc/geoclue/geoclue.conf 添加 MLS API key
```

## 相关命令速查

```bash
# ModemManager 状态
sudo mmcli -L                          # 列出 modem
sudo mmcli -m 0                        # 查看 modem 详情
sudo mmcli -m 0 --location-status       # 查看 GPS 状态
sudo mmcli -m 0 --location-enable-gps-nmea  # 启用 GPS NMEA 输出

# QMI 诊断
qmicli -d qrtr://0 --dms-get-capabilities    # 检查 modem 能力
qmicli -d qrtr://0 --uim-get-card-status      # 检查 SIM 卡

# QRTR 调试
ls /sys/bus/qrtr/devices/                     # QRTR 总线设备
cat /sys/kernel/tracing/events/qrtr/*/enable  # 查看 QRTR 事件

# 服务管理
sudo systemctl status ModemManager
sudo systemctl status rmtfs
sudo systemctl status msm-modem-uim-selection
journalctl -u ModemManager -f                  # 实时日志
```

## 结论

GPS 不工作的直接原因是 **modem 因缺少 SIM 卡而无法完成初始化**，QMI 的 GNSS/LOC 服务不可用。

插入 SIM 卡是最有效的解决方案。若无 SIM 卡，可考虑使用 WiFi 定位作为替代方案。

# Razer 2.4G 电量协议（Viper V2 Pro / V3 Pro）

本文记录 BattBar（电量栏）中 Razer 适配器的实现依据。协议字段来自 OpenRazer 的公开源码，未复制其代码；这里只保留只读电量查询所需的协议事实：

- [razercommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c)
- [razermouse_driver.c](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.c)
- [razermouse_driver.h](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.h)（PID 与等待时间）
- [razerchromacommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c)

> 状态：**已真机验证（Viper V2 Pro 无线 `0x00A6`，Windows 10 19045，2026-10-31）**：
> 电量读到 100%、与雷云一致，电量与充电命令均返回 `status=0x02`。
> **Viper V3 Pro（`0x00C1`）与 HyperPolling 接收器（`0x00B3`）仍没有真机**，但走同一套代码与协议。

## 设备

| 设备 | VID | PID |
| --- | --- | --- |
| Viper V3 Pro（无线） | `0x1532` | `0x00C1` |
| Viper V3 Pro（有线） | `0x1532` | `0x00C0` |
| Viper V2 Pro（无线） | `0x1532` | `0x00A6` |
| Viper V2 Pro（有线） | `0x1532` | `0x00A5` |
| HyperPolling 无线接收器 | `0x1532` | `0x00B3` |

应用识别上表中的 `0x00C1` / `0x00B3` / `0x00A6` / `0x00A5`（核心的
`razer::SUPPORTED_PIDS`）。无线鼠标接在接收器上时，系统里看到的是接收器 PID，而不是鼠标 PID；
这些设备都使用下面的事务 ID。

## 报告结构

请求和应答都是 **90 字节的 HID feature report**，report ID 为 `0`：

```text
偏移   长度   字段
0      1      status
1      1      transaction id
2      2      remaining packets（大端，通常 0）
4      1      protocol type（0）
5      1      data size（本查询为 2）
6      1      command class（0x07）
7      1      command id
8      80     arguments
88     1      CRC
89     1      reserved（0）
```

CRC：

```text
crc = XOR(report[2..87])
```

## 查询电量

```text
command class = 0x07
command id    = 0x80
data size     = 2
transaction   = 0x1F   # Viper V3 Pro / HyperPolling 系列
```

请求的关键字节：

```text
00 1f 00 00 00 02 07 80 00 00 ... 00 85 00
                                          ^ CRC
```

CRC 只覆盖 byte 2..87（不含事务 ID），因此为 `0x02 ^ 0x07 ^ 0x80 = 0x85`。

应答字段：

```text
status       0x02 = 成功；0x01 = busy（仍可能带有效参数）
arguments[0] 保留
arguments[1] 电量原始值 0..255
```

换算：

```text
battery = round(arguments[1] * 100 / 255)
```

例如 `arguments[1] = 128` → 50%。

## 查询充电状态

```text
command class = 0x07
command id    = 0x84
data size     = 2
transaction   = 0x1F
```

应答 `arguments[1]`：

```text
0 = 未充电
1 = 充电中
```

## 真机抓包（Viper V2 Pro，Windows 10 / 2026-10-31）

鼠标满电、接着 2.4G 接收器、雷云同时运行。每个 feature report 都是 **91 字节**：
首字节是 report ID（`0x00`），后面才是 90 字节结构。

```text
电量  GET 00 02 1f 00 00 00 02 07 80 00 ff 00 00 …   status=0x02 args[1]=0xff → 100%
充电  GET 00 02 1f 00 00 00 02 07 84 00 00 00 00 …   status=0x02 args[1]=0x00 → 未充电
```

鼠标休眠时接收器立刻返回 `status=0x04`（超时，`arguments` 全 0），唤醒后第一条命令即恢复
`status=0x02`。应用会把 `0x04` 转成「雷蛇鼠标没有应答（可能已休眠，请动一下鼠标）」。

## 时序与重试

OpenRazer 对 Viper 系列无线接收器使用 `RAZER_VIPER_MOUSE_RECEIVER_WAIT_US = 59900`（约 60 ms），
并在失败时最多重试 5 次，每次间隔 10 ms。本项目 macOS 等待 65 ms、Windows 等待 70 ms，
各重试 5 次，以覆盖调度抖动。

## 状态码

| 值 | 含义 | 应用的处理 |
| --- | --- | --- |
| `0x02` | 成功 | 解码电量/充电 |
| `0x01` | busy，但参数有效 | 与 `0x02` 同样解码 |
| `0x03` | 命令失败 | 提示「设备报告命令失败」 |
| `0x04` | 超时（鼠标休眠时最常见） | 提示「动一下鼠标」 |
| `0x05` | 不支持该命令 | 提示「设备不支持该命令」 |

核心通过 `battbar_razer_status()` 把状态字节交给平台层，平台层只负责把已知值翻译成用户能看懂的提示。

## macOS 传输

macOS 上没有 Linux 的 `hidraw`，通过 IOKit 访问：

```swift
IOHIDDeviceSetReport(device,
                     kIOHIDReportTypeFeature,
                     0,                  // report ID
                     report, 90)         // 90 字节结构体
Thread.sleep(forTimeInterval: 0.065)
IOHIDDeviceGetReport(device,
                     kIOHIDReportTypeFeature,
                     0,
                     &response, &length) // length 初始为 90
```

注意点：

- feature report 的 report ID 是 0，90 字节缓冲区从 `status` 开始。
- 应答 `status` 允许 `0x02`（成功）和 `0x01`（busy）。
- 必须校验应答的 `command_class` / `command_id` 与请求一致。
- 雷云（Razer Synapse）可能同时占用接收器；排查时先退出雷云。

## Windows 传输

Windows 上通过 `HidD_SetFeature` / `HidD_GetFeature` 访问，真机（Viper V2 Pro）实测要点：

- 缓冲区必须带 report ID（91 字节，`buffer[0] = 0`），长度按 `HidP_GetCaps` 的
  `FeatureReportByteLength`（本机为 `91`）给；短包会被拒。
- **只有 interface 0 的鼠标集合（usage page `0x0001` / usage `0x0002`）接受 feature report**；
  同一设备其余 11 个集合稳定返回 `ERROR_INVALID_FUNCTION (0x00000001)`。
  核心的 `razer::find_candidates()` 按「interface 0 的鼠标集合优先」排好候选，平台层依次尝试。
- 雷云运行时会独占读写句柄：读/写方式 `CreateFile` 失败，但零权限（`dwDesiredAccess = 0`）
  打开后 `HidD_*` feature 调用仍然可用。枚举阶段也必须走这个兜底，否则被占用的集合会整条消失
  （BattBar 早期版本就是这样把唯一能应答的集合丢掉的）。

## 排查

插上接收器后运行：

```bash
"/Applications/BattBar.app/Contents/MacOS/BattBar" --probe   # macOS
release\win\BattBar.exe --probe                              # Windows，另写 %TEMP%\battbar-probe.txt
```

会打印 HID 集合、核心选出的候选、逐个候选的读写尝试、电量和状态码或错误原因。

若显示 `RAZER_NO_RESPONSE` / `status=0x04`，通常是鼠标休眠；`ERROR_INVALID_FUNCTION` 说明试到了
非鼠标集合；`无法打开` 说明被其他软件独占（雷云/HID 驱动）。

# Razer Viper V3 Pro 2.4G 电量协议

本文记录 BattBar（电量栏）macOS 原生版中 Razer 适配器的实现依据。协议字段来自 OpenRazer 的公开源码，未复制其代码；这里只保留只读电量查询所需的协议事实：

- [razercommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c)
- [razermouse_driver.c](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.c)
- [razerchromacommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c)

> 状态：**实验性**。代码路径已完成，并用手头的协议测试验证了封包、CRC 和换算；编写时没有 Viper V3 Pro 真机，因此尚未做硬件回归。

## 设备

| 设备 | VID | PID |
| --- | --- | --- |
| Viper V3 Pro（无线） | `0x1532` | `0x00C1` |
| Viper V3 Pro（有线） | `0x1532` | `0x00C0` |
| HyperPolling 无线接收器 | `0x1532` | `0x00B3` |

应用当前识别 `0x00C1` 和 `0x00B3`。如果 Viper V3 Pro 通过 HyperPolling 接收器连接，系统里看到的是接收器 PID，而不是鼠标 PID；两种 PID 都使用下面的事务 ID。

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

## 时序与重试

OpenRazer 对 Viper V3 Pro 无线接收器使用 `RAZER_VIPER_MOUSE_RECEIVER_WAIT_US = 59900`（约 60 ms），并在失败时最多重试 5 次，每次间隔 10 ms。本项目使用 65 ms 等待和最多 5 次重试，以覆盖调度抖动。

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

## 排查

插上接收器后运行：

```bash
"/Applications/小鼠电量.app/Contents/MacOS/MouseBattery" --probe
```

会打印发现的设备、电量或错误。若显示 `RAZER_NO_RESPONSE`，通常是鼠标休眠、接收器被雷云占用，或该接收器固件需要不同的事务 ID / report index。

如果后续拿到真机，优先确认：

1. `IOHIDDeviceSetReport` 是否接受 90 字节、report ID 0 的 feature report；
2. 应答是否包含 `transaction_id = 0x1F`，以及 `status` 的实际值；
3. 接收器在 macOS 上是否暴露了正确的 HID collection（可能有多个 PID 相同、usage 不同的接口）。

确认后即可把该适配器从「实验性」升级为「已验证」。

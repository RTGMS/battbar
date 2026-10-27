# ATK / Compx 电量 HID 协议说明

本文记录 BattBar（电量栏）中 ATK 2.4G 接收器电量读取所依据的协议。实现参考了 ATK HUB Web 版（WebHID）公开加载的 Compx 方案代码，并用 ATK 1K 接收器在 macOS 上实测验证。

> 协议可能随固件或接收器型号变化。本项目只做只读电量查询，不写入鼠标配置。

## 设备定位

ATK 1K 接收器（示例）：

- 厂商：Compx
- 产品名：`ATK Mouse 1K Dongle`
- VID：`0x373B`（旧款也有 `0x3554`）
- PID：`0x101A`
- HID 接口：interface 1
- 厂商集合：`usagePage = 0xFF04`，`usage = 0x02`
- 报告：
  - 输入 report `0x08`：16 字节
  - 输出 report `0x08`：16 字节
  - Feature report `0x06`：7 字节（本应用不使用）

### macOS 上的枚举差异

macOS 的 IOHIDManager 和 node-hid 看到的 collection 不完全一样：

- node-hid / HIDAPI 能看到 `usagePage 0xFF04 / usage 0x02`；
- IOHIDManager 在 macOS 27 上只暴露 `usagePage 0xFF05 / usage 0` 的顶层 collection，而 report `0x08` 实际定义在该 collection 的 report descriptor 内（usage page `0x02FF`）。

因此原生版不再硬编码 `0xFF04/0x02`，而是：

```text
vendorId ∈ {0x373B, 0x3554}
primaryUsagePage ≥ 0xFF00
```

然后在候选 collection 上直接发送 report 8 查询。这样 node-hid 和 IOKit 两条路径都能命中同一个接收器。

## 请求

通过 report ID `0x08` 发送 16 字节数据：

```text
byte 0      command = 0x04（GetBatteryLevel）
byte 1      status = 0
byte 2..3   eeprom address = 0
byte 4      data valid length = 0
byte 5..14  zero
byte 15     checksum
```

校验和：

```text
checksum = (0x55 - ((0x08 + sum(bytes[0..14])) & 0xFF)) & 0xFF
```

因为 `bytes[0] = 0x04`，其余为 0，实际请求固定为：

```text
08 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 49
^ report id
```

- **node-hid**：写入 17 字节（report ID + 16 字节数据）。
- **macOS IOKit**：`IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x08, buffer, 17)`，buffer 的第一字节同样是 `0x08`。这一点容易踩坑：如果只传 16 字节 payload，写入会返回成功，但接收器不会应答。
- **WebHID**：`sendReport(8, data16)`，report ID 由浏览器处理。

## 应答

输入 report `0x08` 的 16 字节 payload：

```text
byte 0      command = 0x04
byte 1      status（0 表示成功）
byte 2..3   eeprom address
byte 4      data valid length
byte 5      battery level（0..100）
byte 6      charging flag（1 = 充电中）
byte 7..8   little-endian 电压原始值（ATK HUB 读取但未在 UI 使用）
...
byte 15     checksum
```

macOS 的输入回调会在 buffer 前带上 report ID，因此实际收到 17 字节。原生解析器会同时接受「带 report ID」和「不带 report ID」两种形式。

### 实测样例

电量 25%、未充电：

```text
08 04 00 00 00 02 19 00 0e 3d 00 00 00 00 00 00 e3
                        ^^ ^^
                        25 0
```

电量 100%、充电中：

```text
08 04 00 00 00 02 64 01 10 72 00 00 00 00 00 00 60
                     ^^ ^^
                    100 1
```

电压原始值（例如 `0x3d0e = 15630`）不像单节锂电池电压，可能是 ADC 原始值或特殊编码，因此 UI 不展示电压，避免误导。

## 读取窗口与重试

原生版在独立 utility 线程上读取：

1. 打开候选 HID collection；
2. 注册输入 report 回调并 schedule 到当前 run loop；
3. 写入 17 字节请求；
4. 最多等待 1.4 秒；
5. 超时后重试一次，总计最多约 2.8 秒；
6. 读取结束后关闭 handle，不在两次刷新之间占用接收器。

旧 Electron 版使用 `worker_threads` + `readTimeout` 分片读取，主进程 4.2 秒后强制结束 Worker，避免阻塞界面。该实现保留在 `electron/providers/`，作为 Windows 过渡版本参考。

## 其他实现注意事项

- 读取完成后立即关闭 HID handle，避免长期占用接收器。
- 设备 ID 不使用 HID path（path 在重连后可能变化），否则用户选择会丢失。
- 当接收器仍在、但鼠标休眠时，读取会超时；这是正常现象。应用会保留上一次成功读数并显示 `~`。
- 目前不解析 CID/MID 来识别具体鼠标型号，ATK HUB 的型号映射表很大且不属于电量读取必需步骤。
- 不同接收器可能使用不同 usage page，但 report ID / 命令 / 校验和一致；优先按 report descriptor 中的 report 8 判断。

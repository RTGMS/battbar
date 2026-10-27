# BattBar TODO / 待办与硬件验证

更新：2026-10-26
状态图例：`P0` 阻塞发布 · `P1` 重要但不阻塞 · `P2` 后续

当前只剩两类真机验证没有完成：

- **Razer Viper V3 Pro 2.4G**：代码已完成，没有设备，未做硬件回归。
- **Windows 原生版**：还没开始；现有 Electron Windows 版只作为过渡。

macOS 的 ATK 2.4G 已真机验证。菜单栏长名称滚动、多设备轮播、全屏隐藏已做组件/模拟验证，但还没有真实多鼠标、真实全屏 App 的完整回归。

## 换电脑后先做这 4 步

1. 安装依赖：`npm install`（需要 64 位 Node.js 24，与 CI 一致）。
2. 枚举 HID，确认接收器被系统看到：

   ```bash
   npm run probe:hid
   npm run probe:atk
   npm run probe:razer
   ```

   `probe:razer` 通过 `node-hid` 直接发送 90 字节 feature report，不依赖原生 Windows 版，可以先验证协议。

3. macOS 上验证 Razer：退出 BattBar 后运行原生探针：

   ```bash
   "/Applications/小鼠电量.app/Contents/MacOS/MouseBattery" --probe
   ```

4. 把输出、接收器 VID/PID、系统版本填到文末的[验证记录](#验证记录模板)，发回来即可。

> Windows 的 `node-hid` 使用预编译二进制；如果加载失败，确认 Node 是 64 位，并尝试 `npm rebuild node-hid`。macOS 上也可以用同一套 Node 探针做对照。

---

<a id="p0-razer-viper-v3-pro-24g-真机验证"></a>
<a id="p0-razer-viper-v3-pro-24g-hardware-validation"></a>
## P0 · Razer Viper V3 Pro 2.4G 真机验证 / Hardware Validation

### 当前实现

- 设备：Viper V3 Pro 无线 `0x1532:0x00C1`；HyperPolling 无线接收器 `0x1532:0x00B3`。
- 协议：90 字节 HID feature report，report ID `0`。
- 事务 ID：`0x1F`（Viper V3 Pro / HyperPolling 系列）。
- 电量：class `0x07`，command `0x80`，data size `2`；`battery = round(arguments[1] * 100 / 255)`。
- 充电：class `0x07`，command `0x84`，data size `2`；`arguments[1] == 1`。
- CRC：`XOR(report[2..87])`；电量请求的 CRC 为 `0x85`。
- 时序：等待 65 ms，失败重试最多 5 次（OpenRazer 使用 59.9 ms）。
- 代码：[RazerProvider.swift](macos/BattBar/Sources/Providers/RazerProvider.swift)、[RazerProtocol.swift](macos/BattBar/Sources/Providers/RazerProtocol.swift)
- 文档：[docs/razer-protocol.md](docs/razer-protocol.md)

### 验证前准备

- [ ] Viper V3 Pro 鼠标 + 2.4G 接收器（或 HyperPolling 接收器）。
- [ ] macOS 13+，鼠标切到 2.4G 模式并唤醒。
- [ ] 退出 Razer Synapse / 雷云，避免独占 HID。
- [ ] 退出正在运行的 BattBar（避免两个进程同时打开接收器）。
- [ ] 记录 macOS 版本、鼠标型号、接收器 PID、是否使用 HyperPolling。
- [ ] Windows 上可先用 `npm run probe:razer` 验证协议，再等原生 Windows 版。

### 验证步骤

1. 插入接收器，确认系统能看到 USB 设备：

   ```bash
   ioreg -p IOUSB -l -w 0 | grep -i -B2 -A8 'Razer\|1532'
   ```

2. 运行原生探针，保存完整输出：

   ```bash
   "/Applications/小鼠电量.app/Contents/MacOS/MouseBattery" --probe | tee ~/battbar-razer-probe.txt
   ```

3. 预期看到类似：

   ```text
   DEVICE: razer | Razer Viper V3 Pro | 67% | 2.4 GHz | stale=false
   ```

4. 打开 BattBar 面板，确认电量、充电状态、数据来源。
5. 插拔充电线，确认 `充电中 / 使用中` 状态切换。
6. 连续读取 10 次（每次间隔 30 秒），确认读数稳定、没有间歇性超时。
7. 让鼠标休眠再唤醒，确认 `~` 上次读数与恢复逻辑正常。
8. 记录内存和 CPU（面板关闭状态）：

   ```bash
   footprint "$(pgrep -x MouseBattery | head -1)"
   ```

9. 在 [验证记录](#验证记录模板) 中填写结果。

### 通过标准

- [ ] `--probe` 识别到 Razer 设备并返回合理电量。
- [ ] 电量与雷云/鼠标显示相差不超过 1–2%。
- [ ] 充电状态与实际插线状态一致。
- [ ] 连续 10 次读取成功率 100%，无明显延迟累积。
- [ ] 休眠/唤醒后能恢复，失败时保留上次读数。
- [ ] 面板、菜单栏、通知均能正常显示 Razer 设备。
- [ ] 失败时能给出可读错误，不崩溃、不卡 UI。

### 失败排查

按顺序记录，不要只记“读不到”：

1. **没有候选设备**
   - 确认接收器 PID 是 `0x00C1` 还是 `0x00B3`；如果是其他 PID，先加入 `supportedPIDs` 再测。
   - 用 `ioreg` / `system_profiler SPUSBDataType` 确认接收器真的枚举。
   - 某些接收器可能只暴露一个复合 HID collection；记录 product string 和 usage page。

2. **有候选但 `IOHIDDeviceSetReport` 失败**
   - 记录 `kIOReturn` 错误码。
   - 检查 feature report 长度是否为 90、report ID 是否为 0。
   - 用 HID report descriptor 确认控制接口；Razer 接收器可能有多个同 PID、不同 usage 的 collection。
   - 不要用 `kIOHIDOptionsTypeSeizeDevice` 抢设备，先确认普通 open 可行。

3. **写入成功但无应答**
   - 记录原始请求 hex、`IOHIDDeviceGetReport` 的返回长度和前 16 字节。
   - 检查等待时间（65 ms 是否足够，可试 100 ms）。
   - 检查 `transaction_id`：Viper V3 Pro 应为 `0x1F`，但个别固件可能不同。
   - 检查 `command_class`、`command_id`、`data_size` 和 CRC 是否被正确写入。
   - 退出 Synapse 后重试；Synapse 可能持续占用控制接口。

4. **有应答但 status 不是 0x02 / 0x01**
   - 记录 status、class、command、arguments。
   - `0x03` = failure，`0x05` = not supported；可能是命令或事务 ID 不匹配。
   - 尝试读取 firmware / serial 命令，确认设备是否接受 90 字节 feature report，以区分“协议不对”和“电量命令不支持”。

5. **电量明显不对**
   - 记录 `arguments[0..3]` 原始值。
   - 确认使用的是 `arguments[1]`，并按 `*100/255` 四舍五入。
   - 不要用 `arguments[0]` 或百分比字符串猜测。

6. **macOS 返回长度是 91 而不是 90**
   - 某些 HID 栈会在 feature report 前带 report ID。
   - 如果首字节是 `0x00` 且后续字段整体后移，增加兼容分支；记录真实返回长度。

### 通过后要改的文件

- [ ] `docs/razer-protocol.md`：状态从“实验性”改为“已真机验证”，补真实响应样例。
- [ ] `macos/BattBar/Tests/main.swift`：加入抓到的真实响应 hex 作为测试向量。
- [ ] `README.md` / `README.en.md`：更新验证状态表，去掉“待真机验证”。
- [ ] `RazerProvider.swift`：如果实测需要不同的等待/重试/索引，更新并注明原因。
- [ ] 发布新 DMG / ZIP，更新 `SHA256SUMS.txt`。

---

<a id="p0-windows-原生版"></a>
<a id="p0-native-windows-app"></a>
## P0 · Windows 原生版 / Native Windows App

### 目标

- 原生 Windows 托盘应用，空闲内存目标 **< 40 MB**（争取 < 25 MB）。
- 支持 ATK / VXE / MAD 2.4G、Razer Viper V3 Pro 2.4G、系统蓝牙鼠标。
- 单击托盘图标打开电量面板；托盘 tooltip 显示所有设备。
- 开机启动、低电量通知、刷新间隔、失败保留上次读数。
- 不要求管理员权限，不联网。

### 先要决定的事

- [ ] **UI 技术栈**
  - 方案 A：C# .NET 8 + WinForms `NotifyIcon`，开发快，预计 30–50 MB。
  - 方案 B：C++ Win32 + 自绘托盘/弹窗，内存最低，预计 10–20 MB，但开发慢。
  - 方案 C：Rust + `tray-icon` + 原生 Win32 弹窗，兼顾体积和开发效率，需要评估。
  - 建议先做 2 天原型，用 `footprint` 类似工具（Task Manager / `Get-Process`）对比后定。
- [ ] **托盘如何显示电量**
  - Windows 通知区域只支持图标，不支持 macOS 这种“名称 + 电量”文本。
  - 推荐：托盘图标绘制电量数字/圆环；tooltip 列出 `名称：电量`；点击打开面板显示完整列表。
  - 备选：始终置顶的小悬浮条（可能影响游戏/全屏，默认关闭）。
- [ ] **全屏时是否隐藏**
  - Windows 任务栏本身通常会自动隐藏；是否隐藏托盘图标需要产品决策。
  - 如实现：检测前台窗口覆盖显示器 + 任务栏自动隐藏状态，再隐藏图标；退出全屏恢复。
- [ ] **多设备轮播**
  - 托盘图标每 5.5 秒切换一个设备的电量数字/颜色；tooltip 显示全部。
  - 不使用 macOS 的上下文字动画（Windows 托盘不支持）。

### 实现清单

- [ ] 新建 `windows/` 原生工程，确定构建工具（MSBuild / CMake / Cargo）。
- [ ] 单实例锁：重复启动时唤起已有实例的面板。
- [ ] HID 传输层：HIDAPI（`hidapi.dll`）或 `HidSharp`；封装枚举、open、write、read、feature report。
- [ ] ATK Provider
  - [ ] VID `0x373B` / `0x3554`，PID `0x101A` 及后续型号。
  - [ ] 17 字节写入（report ID `0x08` + 16 字节 payload）。
  - [ ] 读取 report 8，解析 battery/charging；Windows HIDAPI 的 read 缓冲是否包含 report ID 要实测。
- [ ] Razer Provider
  - [ ] VID `0x1532`，PID `0x00C1` / `0x00B3`。
  - [ ] 90 字节 feature report、CRC、事务 `0x1F`、电量/充电命令。
  - [ ] **Windows 特有**：HIDAPI `hid_send_feature_report` 的 report ID 语义与 macOS IOKit 不同；实测 90 / 91 字节两种写入方式，记录哪种被接收器接受。
- [ ] Bluetooth Provider
  - [ ] 优先复用/移植 `electron/providers/windows-bt.ps1` 与 `windows-bluetooth.js` 的 PnP 属性读取逻辑。
  - [ ] 评估 WinRT `Windows.Devices.Bluetooth` 或 SetupAPI；记录哪些鼠标型号暴露 battery 属性。
  - [ ] 过滤鼠标类设备，避免耳机/键盘误报。
- [ ] 托盘 UI
  - [ ] 图标绘制电量数字/颜色；高 DPI 1x/2x 资源。
  - [ ] tooltip 多设备列表。
  - [ ] 点击弹出面板（设备列表、刷新、设置、退出）。
  - [ ] 右键菜单：刷新、低电量提醒、开机启动、退出。
- [ ] 设置持久化：注册表 `HKCU\Software\BattBar` 或 JSON。
- [ ] 开机启动：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，不要求管理员。
- [ ] 低电量通知：Windows Toast（WinRT）或 `NotifyIcon.ShowBalloonTip` 回退；20% / 10% 去重。
- [ ] 休眠/唤醒、锁屏、Explorer 重启后恢复托盘图标。
- [ ] 打包：MSIX 或 Inno Setup；卸载器；可选代码签名。
- [ ] 测试
  - [ ] ATK 协议测试向量（与 macOS 共用）。
  - [ ] Razer CRC/解析测试向量。
  - [ ] 蓝牙 PnP 解析样例。
  - [ ] UI 冒烟测试、单实例、Explorer 重启。
- [ ] CI：Windows runner 构建 + 测试 + 产物上传。

### Windows 验证清单（换电脑后）

- [ ] Windows 10/11 版本：`winver`。
- [ ] 安装旧 Electron 版，确认 ATK 2.4G 是否能读（作为协议对照）。
- [ ] 插 Razer 接收器，确认设备管理器 / USB 设备能看到 PID。
- [ ] 运行 `npm run probe:hid`，保存 VID/PID/usage/report descriptor。
- [ ] 运行 `npm run probe:atk` / `npm run probe:razer`，保存原始 hex。
- [ ] 如果 `node-hid` 加载失败，确认 64 位 Node，并尝试 `npm rebuild node-hid`。
- [ ] 原生 Windows 原型完成后，分别测试 ATK、Razer、蓝牙。
- [ ] 睡眠/唤醒、锁屏、注销、Explorer 重启。
- [ ] 无管理员权限运行。
- [ ] 空闲内存/CPU、安装包大小、卸载残留。
- [ ] 确认没有网络请求。

### Windows 已知问题

- **托盘文本限制**：通知区域不能显示任意文字，这是平台限制，不是实现问题。
- **HID 独占**：Razer Synapse、ATK HUB、其他 HID 工具可能占用设备；需要友好提示。
- **Razer feature report**：Windows HIDAPI 与 macOS IOKit 的 report ID 处理不同，必须两种长度都实测。
- **蓝牙电量**：很多 Windows 鼠标不暴露 PnP battery 属性；应用只能显示“未知”，不能凭空计算。
- **DPI/多屏**：托盘图标和弹窗需要 Per-Monitor DPI 感知。
- **代码签名**：未签名安装包会触发 SmartScreen；正式发布建议购买证书。
- **旧 Electron 版**：只支持 ATK + PnP 蓝牙，不支持 Razer；不要用它判断 Razer 协议是否可用。

### 验收标准

- [ ] ATK 2.4G 在真实 Windows 机器上读到电量。
- [ ] Razer Viper V3 Pro 2.4G 在真实 Windows 机器上读到电量/充电状态。
- [ ] 至少一款蓝牙鼠标能显示电量（或明确记录系统不暴露）。
- [ ] 空闲内存 < 40 MB，CPU 接近 0。
- [ ] 开机启动、通知、刷新间隔、失败保留读数可用。
- [ ] 安装/卸载干净，无管理员权限要求，无网络请求。
- [ ] 通过 24 小时挂机 + 游戏/全屏场景测试。

---

## P1 · macOS 剩余收尾

- [ ] 真实多鼠标同时接入，验证 5.5 秒轮播和面板选择。
- [ ] 真实超长名称设备（或注入测试设备）验证跑马灯长期运行。
- [ ] 真实全屏 App（游戏/视频/Safari）验证隐藏/恢复，而不只是覆盖窗口。
- [ ] 蓝牙鼠标真机验证（Magic Mouse / MX Master / 其他）。
- [ ] 开机启动在 `/Applications` 安装后的真实注册/注销测试。
- [ ] 通知权限在旧 Electron 版升级到原生版后的迁移测试。
- [ ] 英文 UI 本地化（当前面板文案为中文）。
- [ ] 品牌统一：macOS bundle 改为 `BattBar.app`，保留 `com.mousebattery.app` 以迁移权限；更新登录项、DMG 名称、文档路径。
- [ ] Developer ID 签名 + 公证（需要 Apple Developer 账号）。
- [x] GitHub Actions：`ci.yml`（macOS 原生测试/构建/打包 + Windows 旧版测试/构建）与 `release.yml`（tag 发布 DMG/ZIP/EXE + SHA256 + GitHub Release）。

---

## P2 · Linux

- [ ] UI 方案：GTK4 / Qt / Rust tray；目标内存 < 50 MB。
- [ ] HID：`hidraw` + `HIDIOCGFEATURE` / `HIDIOCGINPUT`。
- [ ] ATK report 8、Razer 90 字节 feature report 复用协议文档和测试向量。
- [ ] 蓝牙：BlueZ D-Bus `org.bluez.Battery1`。
- [ ] 桌面环境兼容：GNOME / KDE / Xfce 托盘（AppIndicator）。
- [ ] 打包：AppImage / .deb / Flatpak（注意 hidraw 权限和 udev 规则）。

---

## 验证记录模板

| 日期 | 平台 | 设备 | 连接 | 结果 | 读数 | 日志/备注 |
| --- | --- | --- | --- | --- | --- | --- |
|  | macOS | ATK Mouse 1K Dongle | 2.4G | ✅ | 100% | 2026-10-26 已验证 |
|  | macOS | Razer Viper V3 Pro | 2.4G | 待测 |  |  |
|  | Windows | ATK Mouse 1K Dongle | 2.4G | 待测 |  |  |
|  | Windows | Razer Viper V3 Pro | 2.4G | 待测 |  |  |
|  | macOS | 蓝牙鼠标 | BT | 待测 |  |  |

记录时附上：

- OS 版本 / 应用版本。
- 接收器 VID/PID、product string。
- `--probe` 或诊断输出的完整文本。
- 失败时的请求/响应 hex（去掉隐私信息）。
- 是否运行 ATK HUB / Synapse。

---

## 相关文档

- [README（中文）](README.md)
- [README (English)](README.en.md)
- [ATK 协议](docs/atk-protocol.md)
- [Razer 协议](docs/razer-protocol.md)
- [HID 验证探针](tools/hid-probe.js)

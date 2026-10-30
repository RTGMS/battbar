# BattBar TODO / 待办与硬件验证

更新：2026-10-30
状态图例：`P0` 阻塞发布 · `P1` 重要但不阻塞 · `P2` 后续

当前只剩两类真机验证没有完成：

- **Razer Viper V3 Pro 2.4G**：代码已完成，没有设备，未做硬件回归。
- **Windows 原生版**：C# 托盘版代码已完成，但一次都没在 Windows 上跑过；协议核心已完成（见下方 P0 · Windows 原生版）。

macOS 的 ATK 2.4G 已真机验证。菜单栏长名称滚动、多设备轮播、全屏隐藏已做组件/模拟验证，但还没有真实多鼠标、真实全屏 App 的完整回归。

架构决定（2026-10-27）：**UI 按平台分开，协议核心统一用 Rust**。macOS 继续用 Swift/AppKit，
Windows 用 C# / WinForms，两端共用 [`core/`](core/README.md)。已经验证：`cargo check --target
x86_64-pc-windows-msvc` 与 `dotnet build` 在 macOS 上可通过，C ABI 可从 Swift 正常调用。


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
   "/Applications/BattBar.app/Contents/MacOS/BattBar" --probe
   ```

4. 把输出、接收器 VID/PID、系统版本填到文末的[验证记录](#验证记录模板)，发回来即可。

> Windows 的 `node-hid` 使用预编译二进制；如果加载失败，确认 Node 是 64 位，并尝试 `npm rebuild node-hid`。macOS 上也可以用同一套 Node 探针做对照。

---

<a id="p0-rust-协议核心"></a>
<a id="p0-shared-rust-core"></a>
## P0 · Rust 协议核心 / Shared Rust Core

目标：**协议只写一份**，平台层只负责开设备、读字节、画界面。

### 已完成（2026-10-27）

- [x] 新建 `core/` workspace：`battbar-core`（纯逻辑）+ `battbar-ffi`（C ABI）。
- [x] ATK：组包 / 校验和 / 解码 / 候选过滤 / 显示名 / 稳定 ID（含 SHA-1 指纹，兼容旧 Electron 的选择记忆）。
- [x] Razer：90 字节 feature report / CRC / 电量换算 / 充电解码 / 91 字节前缀兼容。
- [x] 蓝牙：macOS 属性优先级、Windows PnP 校验、鼠标识别（去空格、大小写不敏感）。
- [x] 低电量提醒：20% / 10% 去重、充电与恢复到 25% 后重新武装、设备消失后忘记。
- [x] `core/vectors/vectors.json` 共享测试向量 + 三方对拍（Rust / Swift / JS）。
- [x] C ABI + 头文件 + Swift 冒烟测试（`core/scripts/build-macos.sh`）。
- [x] CI：`core` job（fmt / clippy / test / 双对拍 / FFI）、`core-windows` job（MSVC 编译检查）。
- [x] `cargo check --target x86_64-pc-windows-msvc` 在 macOS 上通过。

当前结果：`cargo test` 67 通过；JS 对拍 40 通过 3 跳过；Swift 对拍 45 通过 1 跳过；FFI 冒烟通过。

真机交叉验证（2026-10-27，本机 ATK 1K 接收器，`core/scripts/hardware-test-macos.sh`）：

- 连续读取 **30/30 成功**，超时 0 次，每次 21–26 ms。
- 同一份报文交给**已发布的 Swift 实现**和 **Rust 核心**解码，30 次结果全部一致。
- 核心生成的请求字节与 Swift 完全相同。
- 已发布 App 的 `--self-test` 在本机 PASS（设备 1 台、面板正常开关）。
- 进程峰值内存：30 次真机读取 + 解码的测试程序 9.6 MB；正在运行的 BattBar.app
  `phys_footprint` 38 MB（峰值 135 MB，当时面板开过）。

**关于枚举模型（修正）**：我最初写成"macOS 与 Windows 的设备枚举不同"，**这是错的**。
查 hidapi 源码后确认差异在 **API**，不在系统：

- `hidapi/mac/hid.c` 的 `create_device_info()` 把 IOKit 的每设备结果按 usage pair **自己展开**
  （本机实测 3 设备 → 11 条记录）。
- `hidapi/windows/hid.c` 用 `CM_Get_Device_Interface_ListW` 枚举 device interface，本身就是按 collection。

所以：hidapi（node-hid / Rust hidapi crate）→ 每 collection 一条；裸 IOKit → 每设备一条。
核心保留两套规则（`find_candidates` / `battbar_atk_is_macos_candidate`），按**调用方的 API** 选，
不是按系统选。已加不变式测试断言两张真实设备表描述同一批物理设备。

**关于内存（结论被真机推翻）**：我最初用离屏探针测出"面板每次打开泄漏约 4.4 MB"，
并据此改了 `PanelController`。**这个结论是错的**——离屏面板不参与真实合成，图层会累积，
造就了假的线性增长。换成真实应用 + 真实面板开合后：

| 版本 | 首次 | 关闭后稳定值 | 30 次开合后 |
| --- | --- | --- | --- |
| 修复前（HEAD） | 14 MB | 36 MB | 36 MB（无漂移） |
| 我的"修复" | 14 MB | 36 MB | 36 MB（无差别） |

- **没有泄漏**：开合 3 次后稳定在 36 MB，30 次后仍 36 MB。
- 面板打开时峰值 95–127 MB，主要是图形缓冲（graphics 66 MB + IOSurface 13 MB），关闭后归还大部分。
- 已把 `PanelController` / `PanelView` 的改动**回退**（无收益，减少风险），
  只在 `AppDelegate` 保留一个测试钩子 `BATTBAR_PANEL_CYCLES`（仅测试用，可随时删）。
- README 的性能表已按实测更新。

**教训**：性能结论必须用真实应用、真实数据、真实屏幕测；离屏/合成数据会给出错误答案。

### 待办

- [x] macOS 版接入核心（2026-10-27）：`ATKProtocol` / `RazerProtocol` 已改为 FFI 调用，
      `build-native.sh` 按架构编译静态库并链接；应用自身的 34 项 Swift 测试现在验证的是 Rust 核心。
      真机：`--probe` 读到 95%，`--self-test` PASS，硬件回环 21 项检查 0 失败。
- [x] 蓝牙规则接入核心（2026-10-27）：`BluetoothProvider` 只负责跑 `system_profiler` 和走 JSON 结构，
      属性选择 / 充电解析 / 鼠标识别 / 稳定 ID 全部走 C ABI。
- [x] 低电量去重接入核心：`NotificationService` 只负责发通知和文案，阈值与状态由核心维护。
- [x] 设备合并/保留/排序/当前选中策略接入核心（`core/battbar-core/src/merge.rs`），
      `AppModel.apply` 只重建模型对象。
- [x] 删掉 Swift 里最后一处重复工具函数 `normalizedBattery`。
- [ ] 真机验证后再删除 Swift/JS 里的重复协议实现。
- [ ] 补齐 `bluetooth` 的 Swift 对拍覆盖面（目前 Swift 侧只覆盖 ATK / Razer / 蓝牙属性）。

> 已知差异（核心已修正、旧实现保留）记录在 [core/README.md](core/README.md#已知差异有意为之)：
> ATK 短包、短包里的非零状态码、蓝牙 `-5%` 被误读、Razer 91 字节响应。

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
   "/Applications/BattBar.app/Contents/MacOS/BattBar" --probe | tee ~/battbar-razer-probe.txt
   ```

3. 预期看到类似：

   ```text
   DEVICE: razer | Razer Viper V3 Pro | 67% | 2.4 GHz | stale=false
   ```

   如果读到异常值，用核心的解码器单独验一遍抓到的 hex，排除"协议理解错"还是"传输没拿到"：

   ```bash
   cargo run --manifest-path core/Cargo.toml --example decode-hex -- razer <90字节hex>
   ```

4. 打开 BattBar 面板，确认电量、充电状态、数据来源。
5. 插拔充电线，确认 `充电中 / 使用中` 状态切换。
6. 连续读取 10 次（每次间隔 30 秒），确认读数稳定、没有间歇性超时。
7. 让鼠标休眠再唤醒，确认 `~` 上次读数与恢复逻辑正常。
8. 记录内存和 CPU（面板关闭状态）：

   ```bash
   footprint "$(pgrep -x BattBar | head -1)"
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
<a id="p0-windows-原生版"></a>
<a id="p0-native-windows-app"></a>
## P0 · Windows 原生版 / Native Windows App

### 架构决定

- **协议核心**：复用 [`core/`](core/README.md)，编译成 `battbar_ffi.dll`，C# 通过 P/Invoke 调用。
  **所有规则都在 Rust**（组包、解码、换算、设备选择、命名、稳定 ID、合并排序、提醒阈值）。
- **UI**：C# / .NET 8 + WinForms `NotifyIcon`（原生 Shell 通知区域）。
- **HID 传输**：C# 直接 P/Invoke SetupAPI + `hid.dll`，不引入 hidapi 的 C 依赖。

### 已完成（2026-10-27）

- [x] `windows/BattBar.Windows/` C# 工程，`dotnet build` 通过（在 macOS 上交叉编译校验）。
- [x] `Core.cs` / `CoreBridge.cs`：P/Invoke 与字符串、结构体编组，不含任何判断逻辑。
- [x] `Hid.cs`：SetupAPI 枚举、`CreateFile` 打开、重叠 I/O 带超时读取、feature report。
- [x] `Providers.cs`：ATK / Razer 扫描；候选选择与解码全部走 DLL。
- [x] `BluetoothScanner.cs`：注册表 PnP 电池属性读取，判定规则走 DLL。
- [x] `TrayApplication.cs`：`NotifyIcon` + 菜单（设备选择、刷新、提醒、开机启动、刷新间隔、退出）。
- [x] `BatteryIcon.cs`：32×32 图标绘制电量数字，按电量变色。
- [x] `Settings.cs`（`%APPDATA%\BattBar\settings.json`）、`Autostart.cs`（HKCU Run，免管理员）。
- [x] 单实例 Mutex；扫描在后台线程，UI 不阻塞。
- [x] `windows/build.ps1` 一键构建；CI 增加 `windows-native` job。
- [x] 新增 C ABI：`battbar_atk_select` / `battbar_razer_select`、`battbar_atk_display_name` / `_device_id`、
      `battbar_razer_display_name` / `_device_id`、`battbar_bluetooth_windows_id`。

### 真机待验证（当前没有 Windows 机器）

- [ ] `dotnet publish` 产物能在 Windows 10/11 启动，托盘图标出现。
- [ ] ATK 接收器读到电量；确认 `ReadFile` 缓冲是否带 report id（核心两种都接受）。
- [ ] **Razer**：feature report 是 90 还是 91 字节写入被接受——目前按 91（前置 report id）实现，
      被拒时改 `Providers.Exchange`。
- [ ] 蓝牙：哪些鼠标暴露 PnP 电池属性；不暴露的只能显示"未发现"。
- [ ] Explorer 重启后图标恢复。
- [ ] 高 DPI（125%/150%/200%）下图标与菜单。
- [ ] 空闲内存/CPU 实测（目标 < 40 MB；.NET + WinForms 预计 30–50 MB）。
- [ ] 无管理员权限运行、卸载残留、开机启动注册与注销。

### 已知问题（2026-10-30 审计，等 Windows 机器上处理）

- [ ] **重叠 I/O 的缓冲区生命周期**（`Hid.cs:308`）：`ReadFile` 用的是托管 `byte[]` 和栈上 `OVERLAPPED`，
      `ERROR_IO_PENDING` 之后超时分支只 `CancelIoEx` 就返回，不等 IRP 完成；驱动仍会往那块缓冲写回长度。
      鼠标静音时 ATK 读取每轮都走这条分支。改法：`GCHandle.Alloc(..., GCHandleType.Pinned)`（或非托管缓冲）+
      `AllocHGlobal` 的 `OVERLAPPED`，取消后用 `GetOverlappedResult(..., true)` 等完成再释放。
      验证：`gflags /p /enable BattBar.exe /full` 开页堆，鼠标休眠状态下反复刷新看有没有堆破坏报告。
- [ ] **`ScanResult.Issues` 只写不读**（`Providers.cs:38`，写入点 `:62`/`:80`）：「请唤醒鼠标」「可能被 ATK HUB 占用」
      「无法枚举 HID 设备」这些提示永远不会显示，用户只看到「未发现鼠标」。要先定显示位置（tooltip / 气泡）。
- [ ] **`Settings.Save()` 吞掉所有写入异常**（`Settings.cs:56`）：目录不可写时菜单勾选与磁盘静默不一致；
      `Autostart.Set()` 写注册表和写 JSON 是两次独立写入，可能一边成功一边失败。
- [ ] **Razer command class 仍硬编码 `0x07`**（`Providers.cs:226`）：核心没导出 getter，要加
      `battbar_razer_command_class()` 才能像 ATK 那样彻底去掉副本。

### 2026-10-30 已修（还没在 Windows 上跑过）

- [x] 启动就退出：构造函数在 `Application.Run` 之前调 `Refresh()`，而 `Refresh()` 在
      `TaskScheduler.FromCurrentSynchronizationContext()` 处因 `SynchronizationContext.Current == null`
      抛 `InvalidOperationException`，异常穿出 `Main`，托盘图标永远不出现（`TrayApplication.cs:108`）。
      首次扫描改为 `Application.Idle` 触发。**真机上先确认这一条：托盘图标要出现。**
- [x] 每轮扫描泄漏两个 CoTaskMem 字符串（`CoreBridge.cs:224` 的 `BuildSummaries` 只释放了结构体数组）。
- [x] 每次右键泄漏一个 `ContextMenuStrip`；`_retryTimer` 也从未 `Dispose`（`TrayApplication.cs:173`、`:269`）。
- [x] 重试预算被吞：重试到点时若有扫描在飞，`_retrying` 置真后提前返回，那次在飞的扫描以「已重试」结束，
      15 秒复查丢失（`TrayApplication.cs:82`）。
- [x] ATK report id 改为问核心（`battbar_atk_report_id()`，`Providers.cs:140`）。

## P1 · macOS 剩余收尾

- [ ] 真实多鼠标同时接入，验证 5.5 秒轮播和面板选择。
- [ ] 真实超长名称设备（或注入测试设备）验证跑马灯长期运行。
- [ ] 真实全屏 App（游戏/视频/Safari）验证隐藏/恢复，而不只是覆盖窗口。
- [ ] 蓝牙鼠标真机验证（Magic Mouse / MX Master / 其他）。
- [ ] 开机启动在 `/Applications` 安装后的真实注册/注销测试。
- [ ] 品牌迁移后重新授权：确认 `com.battbar.app` 的通知权限、开机启动会重新注册。
- [ ] 英文 UI 本地化（当前面板文案为中文）。
- [x] 品牌统一：`BattBar.app` / `com.battbar.app` / `BattBar-*` 产物 / 文档与代码全部更新，旧 Electron 版同步改名（2026-10-27）。
- [ ] Developer ID 签名 + 公证（需要 Apple Developer 账号）。
- [x] GitHub Actions：`ci.yml` 改为手动触发（macOS 原生测试/构建/打包 + Windows 旧版测试/构建）；`release.yml` 仅在 tag 发布 DMG/ZIP/EXE + SHA256 + GitHub Release。

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
- [协议核心 core/](core/README.md)
- [ATK 协议](docs/atk-protocol.md)
- [Razer 协议](docs/razer-protocol.md)
- [HID 验证探针](tools/hid-probe.js)

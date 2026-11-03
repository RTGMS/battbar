# BattBar TODO / 待办与硬件验证

更新：2026-10-31
状态图例：`P0` 阻塞发布 · `P1` 重要但不阻塞 · `P2` 后续

当前只剩真机验证收尾：

- **Windows 原生版**：已在 Windows 10 19045 真机跑通（ATK RS7 Air 41%、Razer Viper V2 Pro 100%），
  剩余少量清单项（高 DPI、Explorer 重启、无管理员运行等）见下方 P0 · Windows 原生版。
- **Razer Viper V2 Pro 2.4G**：已真机验证（Windows，`0x00A6`，100%，与雷云一致）。
  **Viper V3 Pro（`0x00C1`）/ HyperPolling 接收器（`0x00B3`）仍没有设备**，协议同族但未实测。
- **macOS 上的 Razer**：代码与 Windows 共用 Rust 核心，但没有 macOS 真机回归。
- **蓝牙鼠标**：仍然一个真机都没有。

macOS 的 ATK 2.4G 已真机验证。菜单栏长名称滚动、多设备轮播、全屏隐藏已做组件/模拟验证，但还没有真实多鼠标、真实全屏 App 的完整回归。

架构决定（2026-10-27）：**UI 按平台分开，协议核心统一用 Rust**。macOS 继续用 Swift/AppKit，
Windows 用 C# / WinForms，两端共用 [`core/`](core/README.md)。2026-10-31 已在 Windows 真机确认：
C# → `battbar_ffi.dll`（GNU 工具链构建，无需 Visual Studio）可正常调用，托盘图标与读数均正常。


## 换电脑后先做这 4 步

1. 安装依赖：`npm install`（需要 64 位 Node.js 24，与 CI 一致）；Windows 还需要 .NET 8 SDK 和 Rust，
   没有 Visual Studio 时用 `rustup` 的 `x86_64-pc-windows-gnu` 工具链即可（`build.ps1` 会自动选）。
2. 枚举 HID，确认接收器被系统看到：

   ```bash
   npm run probe:hid
   npm run probe:atk
   npm run probe:razer
   ```

   `probe:razer` 通过 `node-hid` 直接发送 90 字节 feature report，不依赖原生版，可以先验证协议。

3. Windows 上另有原生探针（与托盘版同一份代码，可同时运行）：

   ```powershell
   release\win\BattBar.exe --probe     # 同时写入 %TEMP%\battbar-probe.txt
   ```

   macOS 上验证 Razer：退出 BattBar 后运行 `"/Applications/BattBar.app/Contents/MacOS/BattBar" --probe`。

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
## P0 · Razer 2.4G 真机验证 / Hardware Validation

### 已真机验证（2026-10-31，Windows 10 19045）

设备：**Razer Viper V2 Pro 无线 `0x1532:0x00A6`**（雷云在运行）。结果：

- `--probe` 识别为 `Razer Viper V2 Pro | 100% | 使用中`，电量命令与充电命令都返回 `status=0x02`。
- `npm run probe:razer` 独立复核同一读数：`raw=255 battery=100%`、`charging=no`。
- 一次完整扫描（ATK + Razer + 蓝牙）约 250 ms。
- 鼠标休眠时接收器返回 `status=0x04`（无应答）；唤醒后立刻恢复，应用提示「动一下鼠标」而不是报错。

Windows 上真机暴露并已修复的三件事：

1. **只有 interface 0 的鼠标集合接受 feature report**，其余集合返回 `ERROR_INVALID_FUNCTION`（`0x00000001`）。
   核心按「interface 0 的鼠标集合优先」排序候选，平台层依次尝试。
2. **枚举阶段不能用读写方式打开被雷云占用的集合**。之前这些 collection 直接被丢弃，
   而正好丢掉了唯一能应答的鼠标集合 → 托盘一直显示「未发现鼠标」。改为「读写优先、失败退回零权限打开」。
3. **必须按描述符长度发送**：feature report 91 字节（含 report ID）。

### 待验证：Viper V3 Pro / HyperPolling（没有设备，不阻塞发版）

> 现有唯一真机是 **Viper V2 Pro 无线 `0x00A6`**，已全部通过；V3 Pro（`0x00C1`）/ HyperPolling
> 接收器（`0x00B3`）走同一套代码与事务 ID，等有设备再补测，不再算发布阻塞项。

- [ ] Viper V3 Pro 无线 `0x00C1` + 2.4G 接收器（或 HyperPolling 接收器 `0x00B3`）。
- [ ] macOS 13+，鼠标切到 2.4G 模式并唤醒。
- [ ] 退出 Razer Synapse / 雷云，避免独占 HID。
- [ ] 退出正在运行的 BattBar（避免两个进程同时打开接收器）。
- [ ] 记录系统版本、鼠标型号、接收器 PID、是否使用 HyperPolling。
- [ ] 先跑 `npm run probe:razer` 验证协议，再跑原生 `--probe`。

### 当前实现

- 设备：Viper V3 Pro 无线 `0x00C1` / 有线 `0x00C0`；Viper V2 Pro 无线 `0x00A6` / 有线 `0x00A5`；
  HyperPolling 无线接收器 `0x00B3`。
- 协议：90 字节 HID feature report，report ID `0`。
- 事务 ID：`0x1F`（Viper V3 Pro / V2 Pro / HyperPolling 系列）。
- 电量：class `0x07`，command `0x80`，data size `2`；`battery = round(arguments[1] * 100 / 255)`。
- 充电：class `0x07`，command `0x84`，data size `2`；`arguments[1] == 1`。
- CRC：`XOR(report[2..87])`；电量请求的 CRC 为 `0x85`。
- 时序：Windows 等待 70 ms、macOS 等待 65 ms，失败重试最多 5 次（OpenRazer 使用 59.9 ms）。
- 代码：[core/battbar-core/src/razer.rs](core/battbar-core/src/razer.rs)（协议与候选排序）、
  [Providers.cs](windows/BattBar.Windows/Providers.cs)（Windows 传输）、
  [RazerProvider.swift](macos/BattBar/Sources/Providers/RazerProvider.swift)（macOS 传输）。
- 文档：[docs/razer-protocol.md](docs/razer-protocol.md)

### 验证步骤（V3 Pro）

1. 插入接收器，确认系统能看到 USB 设备：

   ```bash
   ioreg -p IOUSB -l -w 0 | grep -i -B2 -A8 'Razer\|1532'
   ```

2. 运行原生探针，保存完整输出：

   ```bash
   "/Applications/BattBar.app/Contents/MacOS/BattBar" --probe | tee ~/battbar-razer-probe.txt
   # Windows
   release\win\BattBar.exe --probe
   ```

3. 预期看到类似：

   ```text
   DEVICE: razer | Razer Viper V3 Pro | 67% | 使用中 | Razer HID | stale=false
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

- [x] `--probe` 识别到 Razer 设备并返回合理电量（V2 Pro 100%）。
- [x] 电量与雷云/鼠标显示相差不超过 1–2%（V2 Pro：雷云 100%，应用 100%）。
- [x] 未插线时显示「使用中」、不带闪电（V2 Pro 当前没有充电）。
- [ ] 插线充电时显示「充电中」（需要给鼠标插线，本轮没测）。
- [ ] 连续 10 次读取成功率 100%，无明显延迟累积（只做了单次与探针复核）。
- [x] 休眠/唤醒后能恢复（休眠返回 `0x04`，唤醒后恢复 100%）。
- [x] 面板、菜单栏、通知均能正常显示 Razer 设备（Windows 菜单与悬浮提示已验证）。
- [x] 失败时能给出可读错误，不崩溃、不卡 UI。

### 失败排查

按顺序记录，不要只记“读不到”：

1. **没有候选设备**
   - 确认接收器 PID 是 `0x00C1` / `0x00B3` / `0x00A6` / `0x00A5`；如果是其他 PID，先加入
     `core/battbar-core/src/razer.rs` 的 `SUPPORTED_PIDS` 再测。
   - 用 `ioreg` / `system_profiler SPUSBDataType`（macOS）或设备管理器（Windows）确认接收器真的枚举。
   - 某些接收器可能只暴露一个复合 HID collection；记录 product string 和 usage page。

2. **有候选但写 feature report 失败**
   - macOS：记录 `kIOReturn` 错误码；Windows：记录 Win32 错误码（`--probe` 已打印）。
   - 检查 feature report 长度是否为 91（90 字节结构 + report ID）和 report ID 是否为 0。
   - **Windows 上只有 interface 0 的鼠标集合会接受写入**；其他集合稳定返回 `ERROR_INVALID_FUNCTION`。
   - 被雷云占用时用零权限打开仍可读写 feature report；枚举阶段必须退回零权限，否则会丢掉集合。

3. **写入成功但无应答**
   - 记录原始请求 hex、返回长度和前 16 字节。
   - 检查等待时间（65–70 ms 是否足够，可试 100 ms）。
   - 检查 `transaction_id`：应为 `0x1F`，但个别固件可能不同。
   - 检查 `command_class`、`command_id`、`data_size` 和 CRC 是否被正确写入。
   - 退出 Synapse 后重试；Synapse 可能持续占用控制接口。

4. **有应答但 status 不是 0x02 / 0x01**
   - 记录 status、class、command、arguments。
   - `0x03` = failure，`0x04` = 超时（鼠标休眠时最常见），`0x05` = not supported。
   - 尝试读取 firmware / serial 命令，确认设备是否接受 90 字节 feature report，以区分“协议不对”和“电量命令不支持”。

5. **电量明显不对**
   - 记录 `arguments[0..3]` 原始值。
   - 确认使用的是 `arguments[1]`，并按 `*100/255` 四舍五入。
   - 不要用 `arguments[0]` 或百分比字符串猜测。

6. **返回长度是 91 而不是 90**
   - 某些 HID 栈会在 feature report 前带 report ID（Windows 与 macOS 都会）。
   - 核心的 `normalize_feature_report` 会自动剥掉前导 `0x00`。

### 通过后要改的文件

- [x] `docs/razer-protocol.md`：状态改为「已真机验证」，补真实响应样例（V2 Pro）。
- [x] `README.md` / `README.en.md`：更新验证状态表，去掉「待真机验证」（V3 Pro 单独标注）。
- [x] `core/battbar-core/src/razer.rs`：按实测补 Viper V2 Pro PID、候选排序和真实响应测试向量。
- [ ] `macos/BattBar/Tests/main.swift`：加入抓到的真实响应 hex 作为测试向量（需要 macOS 构建环境）。
- [ ] V3 Pro 实测后发布新 DMG / ZIP，更新 `SHA256SUMS.txt`。

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
- [x] `BatteryIcon.cs`：32×32 托盘图标（2026-10-31 改成电池轮廓，不再往 16 px 图标里塞数字）。
- [x] `Settings.cs`（`%APPDATA%\BattBar\settings.json`）、`Autostart.cs`（HKCU Run，免管理员）。
- [x] 单实例 Mutex；扫描在后台线程，UI 不阻塞。
- [x] `windows/build.ps1` 一键构建；CI 增加 `windows-native` job。
- [x] 新增 C ABI：`battbar_atk_select` / `battbar_razer_select`、`battbar_atk_display_name` / `_device_id`、
      `battbar_razer_display_name` / `_device_id`、`battbar_bluetooth_windows_id`。

### 真机验证（2026-10-31，Windows 10 Pro 19045，无管理员权限）

环境：.NET SDK 8.0.427（`dotnet-install.ps1` 装到用户目录）、Rust 1.99.1
（`x86_64-pc-windows-gnu` 工具链，**机器上没有 Visual Studio**，GNU 工具链自带链接器）、
Node 24.15.0。设备：ATK RS7 Air（`0x373B:0x1220`）+ Razer Viper V2 Pro（`0x1532:0x00A6`，雷云在运行）。

- [x] `dotnet publish` 单文件产物（146 MB，自包含）能在 Windows 10 启动，托盘图标出现。
- [x] 托盘图标为电池轮廓（按电量填充、按等级变色），不再把数字塞进 16 px 图标。
- [x] **常驻电量文字**直接画在任务栏里（分层窗口、无边框、文字颜色取样自任务栏）：
      每行一台设备「● 名称 电量」，点一下弹出同一个菜单（点别处会关），可拖动且记住位置，
      全屏/任务栏自动隐藏时隐藏，设备太多折叠成「+N 台」。
- [x] 菜单「显示设备」按设备勾选显示（有线鼠标 RS7 Air 收起），
      「常驻电量条」可关掉或归位；设置写进 `%APPDATA%\BattBar\settings.json`
      （`hidden_device_ids`、`show_floating_strip`、`strip_x` / `strip_y`）。
      协议里没有可靠的「有线/无线」标志（雷蛇接收器还会报鼠标本名），所以由用户决定。
- [x] 右键菜单：设备列表（当前设备打勾、已隐藏的标注）、显示设备、常驻电量条、
      问题提示、刷新电量、低电量提醒、开机自动启动、自动刷新、退出。
- [x] ATK 读到电量：41%，`使用中`；应答带前导 `0x00` report id（核心已兼容三种形状）。
- [x] Razer 读到电量：100%，`使用中`；`npm run probe:razer` 独立复核 `raw=255 battery=100%`。
- [x] 鼠标休眠时保留上次读数（`~100%`），不是整台设备消失。
- [x] 一次完整扫描约 250 ms（两把设备都在线时）；常驻内存 37–45 MB（目标 < 40 MB，
      单文件版解压后略高）。
- [ ] 蓝牙：哪些鼠标暴露 PnP 电池属性；不暴露的只能显示"未发现"（本机无蓝牙鼠标）。
- [ ] Explorer 重启后图标恢复。
- [ ] 高 DPI（125%/150%/200%）下图标与菜单。
- [ ] 无管理员权限运行、卸载残留、开机启动注册与注销（本轮没有改系统设置）。
- [ ] 充电中状态（需要给鼠标插线）。

### 2026-10-30 审计项（已全部处理，2026-10-31）

- [x] **重叠 I/O 的缓冲区生命周期**（`Hid.cs`）：`Read`/`Write` 改为
      `GCHandle.Alloc(..., Pinned)` + `AllocHGlobal` 的 `OVERLAPPED` + 事件；超时后
      `CancelIoEx` 再 `GetOverlappedResult(..., true)` 等 IRP 完成才解钉、释放。
      顺带修了 **`WriteFile` 从不传 `OVERLAPPED`** 的问题：句柄用 `FILE_FLAG_OVERLAPPED` 打开，
      同步调用会直接返回 `ERROR_INVALID_PARAMETER`，ATK 指令其实一直发不出去。
- [x] **`ScanResult.Issues` 只写不读**：现在出现在悬浮提示（无设备时）、菜单里的「提示：」行，
      并且每类新问题弹一次气泡提醒（设备恢复后重新武装）。
- [x] **`Settings.Save()` 吞异常**：改为返回 `bool`，写失败时弹气泡说明路径；
      `Autostart.Set()` 也返回 `bool`，勾选状态以注册表为准（`Autostart.Enabled`），
      JSON 写失败不会再让菜单和磁盘静默不一致。
- [x] **Razer command class 硬编码**：核心新增 `battbar_razer_command_class()`，C# 不再有 `0x07` 副本。

### 2026-10-31 真机暴露并修复的问题

- [x] **枚举丢弃被占用的集合**：SetupAPI 枚举后逐个打开取属性，雷云占用的鼠标集合
      （读/写打开失败）被直接丢掉，而**只有这个集合能应答电量命令** → 托盘一直「未发现鼠标」。
      改为「读写优先，失败退回零权限打开」（hidapi 同款兜底）。HID 集合数量 14 → 21。
- [x] **输出报告必须按描述符长度发送**：ATK 请求只有 17 字节，而该集合的 output report 是 385 字节，
      `WriteFile` 短包直接 `ERROR_INVALID_PARAMETER`。现按 `OutputReportByteLength` 补零。
- [x] **ATK 应答带 Windows report id**：真机返回 `00 04 00 00 00 00 29 …`，核心原先只认
      `08 04 …` 或裸包，导致「读到了但一直不认」。核心现在接受三种形状，并加了真机向量测试。
- [x] **ATK 候选规则过窄**：RS7 Air 的控制集合是 `0xFF60/0x61`，旧的「必须是 `0xFF04/0x02`」筛掉了它。
      核心改为接受任意 vendor usage page（`0xFF00+`），`0xFF04/0x02` 仍优先。
- [x] **Razer 候选排序**：核心新增 `razer::find_candidates()`，按「interface 0 的鼠标集合」优先排序；
      平台层依次尝试，某个集合失败不再中断整轮扫描。
- [x] **Razer 状态码可读化**：核心新增 `battbar_razer_status()`；`0x04`（鼠标休眠）提示「动一下鼠标」，
      `0x03` / `0x05` 分别给出失败与不支持。
- [x] **`--probe` 诊断模式**：与 macOS 对齐，逐候选打印打开/写入/读取/解码结果，
      同时写 `%TEMP%\battbar-probe.txt`，可在托盘版运行时执行。
- [x] **`build.ps1` 支持无 Visual Studio**：自动在 MSVC / GNU 目标之间选择，可显式传
      `-RustTarget x86_64-pc-windows-gnu`；`.csproj` 两个目标的 DLL 都能引用。

### 2026-10-31 界面改版（按真机试用反馈）

- [x] 托盘图标改成电池轮廓（填充比例 = 电量，按等级变色，充电时加闪电）。
- [x] **常驻电量文字**（`BatteryStrip.cs`）：用 `UpdateLayeredWindow` 分层窗口把文字直接画在
      任务栏上，没有卡片和边框；背景 alpha = 12（不可见但可点），文字颜色按任务栏实际像素亮度选
      白/深色。位置在通知区域左侧、任务栏内部垂直居中。
- [x] **菜单点外面会关**：改成走 `NotifyIcon` 自己的 `ShowContextMenu`（反射调用私有方法），
      它会先把托盘的消息窗口设为前台，`ContextMenuStrip` 才会在外部点击时消失。
      直接 `menu.Show(...)` 从无激活窗口弹出时永远不关——这就是上一版的问题。
- [x] **全屏隐藏**：每 600 ms 检查前台窗口是否盖住整块屏幕（忽略桌面/任务栏类名）；
      全屏时隐藏，退出全屏恢复。真机用浏览器 F11 验证：maximized 时显示，F11 后隐藏，再按回来。
- [x] **任务栏自动隐藏**：任务栏被移出屏幕（露出不到一半）时同样隐藏。
- [x] **拖动 + 记住位置**：拖动结束后写入 `strip_x` / `strip_y`，重启后回到原位；
      菜单「常驻电量条 → 归位到通知区域左侧」可清掉并重新贴回任务栏。已验证拖动、落盘、重启恢复。
- [x] **竖排任务栏**（左侧/右侧）：改成堆在通知区域上方，宽度限制在任务栏宽度内。
- [x] **设备太多**：先压行高，再折叠成「+N 台」，保证不超出任务栏高度。
- [x] **Explorer 重启**：监听 `TaskbarCreated` 广播，重新添加托盘图标和常驻条
      （`ShellRestartWatcher.cs`）。**代码已实现，本轮没有真的重启资源管理器验证**。
- [x] 「显示设备」按设备勾选显示（有线鼠标 RS7 Air 收起），「常驻电量条」可整体关掉或归位；
      都写进 `settings.json`。
- [x] **休眠保留上次读数**：`ScanAtk` / `ScanRazer` 在候选全部失败时补上 `result.Failed`，
      合并策略（核心）据此把上一次读数标成 stale 保留，任务栏显示 `~100%` 而不是整台消失。
- [x] **就近对齐 macOS 2026-10-31 第二轮**：
      - 读取失败**不再弹气泡**（之前「没有应答」会弹通知，很吵）；通知只留 20% / 10% 低电量，
        失败原因只出现在菜单「提示：」行（对应 macOS 面板的 issue banner）。
      - 悬浮提示文案照 macOS：`名称：上次读数 100%，充电中`；空状态「电量栏 · 未发现鼠标」。
      - 任务栏每行改成 macOS 菜单栏同款：名称 + 电池轮廓（数字画在里面、充电时加闪电、
        stale 时整块变灰并用 secondary 色），不再用「圆点 + 粗体百分比」。
      - 托盘图标改用应用图标（`build/icon.ico`，嵌入资源 + `<ApplicationIcon>`），
        不再每轮扫描现画 32×32 位图。
- [x] **本轮顺手修的 bug**（代码审查 + 实测）：
      - 分层窗口的位图没做 **alpha 预乘**：`UpdateLayeredWindow` 要求预乘，导致半透明填充和
        抗锯齿文字边缘偏亮、颜色发白。现在渲染后先预乘。
      - 重试策略用的是全部设备而不是可见设备：被隐藏的有线鼠标变 stale 也会触发 15 秒补读。
      - 菜单的设备勾选只在手动选过设备后才出现（拿 `SelectedDeviceId` 比较）；现在勾核心算出的当前设备。
      - 全部设备被隐藏时任务栏显示「未发现鼠标」（有歧义）→ 改成「已隐藏全部设备」。
      - 读取超时与 IRP 完成撞车时（`CancelIoEx` 输给刚完成的 IRP）会丢掉刚到的报文；现在先取
        `GetOverlappedResult` 的字节数，有数据就当成功。
      - 任务栏在运行中移动/改高度/换边、或 DPI 变化时，常驻条要等下一轮扫描（最多 60 s）才跟着动；
        现在 600 ms 的看门狗会比对几何签名，一变就重新布局。
      - 验证 `ShellRestartWatcher` 真的能建窗口（`--probe` 现在打印它的 HWND）。

### 已知但未处理

- [ ] 每次扫描会把所有 Razer 候选都试一遍（休眠时 ~1.3 s）。首个候选（interface 0 鼠标集合）
      成功率最高，但失败时仍会继续试完 8 个候选。
- [ ] 常驻条压在任务栏的空白段上，会挡住那一段（不影响通知区域、时钟和「显示桌面」）；
      拖到桌面后它仍是最前一层。
- [ ] 任务栏在屏幕**上方**时没有单独适配（横向仍按「通知区域左侧」算），只覆盖了底部/左右三种。
- [ ] 高 DPI（125% / 150% / 200%）只做了 `DeviceDpi` 缩放和 PerMonitorV2，没有在真机切换缩放验证。
- [ ] Explorer 重启后的恢复只做了代码，没有真机重启验证（怕打断当前桌面）。
- [ ] 插线充电状态、蓝牙鼠标仍未测。

### 更早的修复（2026-10-30 提交，2026-10-31 已在真机确认）

- [x] 启动就退出：构造函数在 `Application.Run` 之前调 `Refresh()`，而 `Refresh()` 在
      `TaskScheduler.FromCurrentSynchronizationContext()` 处因 `SynchronizationContext.Current == null`
      抛 `InvalidOperationException`，异常穿出 `Main`，托盘图标永远不出现（`TrayApplication.cs:108`）。
      首次扫描改为 `Application.Idle` 触发。
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
| 2026-10-26 | macOS | ATK Mouse 1K Dongle (`0x373B:0x101A`) | 2.4G | ✅ | 100% | 充电中 |
| 2026-10-31 | Windows 10 19045 | ATK RS7 Air (`0x373B:0x1220`) | 2.4G | ✅ | 41% | `--probe`，使用中；控制集合 `0xFF60/0x61` |
| 2026-10-31 | Windows 10 19045 | Razer Viper V2 Pro (`0x1532:0x00A6`) | 2.4G | ✅ | 100% | 雷云在运行；电量/充电均 `status=0x02` |
| 2026-10-31 | Windows 10 19045 | Razer Viper V2 Pro（休眠中） | 2.4G | ✅ 预期失败 | — | 接收器 `status=0x04`；唤醒后恢复 100% |
|  | macOS | Razer Viper V3 Pro (`0x00C1`) / HyperPolling (`0x00B3`) | 2.4G | 待测 |  | 没有设备 |
|  | Windows | Razer Viper V3 Pro (`0x00C1`) / HyperPolling (`0x00B3`) | 2.4G | 待测 |  | 没有设备 |
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

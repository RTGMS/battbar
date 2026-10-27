# BattBar TODO / 待办与硬件验证

更新：2026-10-27
状态图例：`P0` 阻塞发布 · `P1` 重要但不阻塞 · `P2` 后续

当前只剩两类真机验证没有完成：

- **Razer Viper V3 Pro 2.4G**：代码已完成，没有设备，未做硬件回归。
- **Windows 原生版**：UI 骨架未开始；协议核心已完成（见下方 P0 · Rust 协议核心）。

macOS 的 ATK 2.4G 已真机验证。菜单栏长名称滚动、多设备轮播、全屏隐藏已做组件/模拟验证，但还没有真实多鼠标、真实全屏 App 的完整回归。

架构决定（2026-10-27）：**UI 按平台分开，协议核心统一用 Rust**。macOS 继续用 Swift/AppKit，
Windows 用 Rust，两端共用 [`core/`](core/README.md)。已经验证：`cargo check --target
x86_64-pc-windows-msvc` 在 macOS 上可通过，C ABI 可从 Swift 正常调用。


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

- [ ] macOS 版接入核心：把 `ATKProtocol.swift` / `RazerProtocol.swift` 的实现换成 FFI 调用，保留现有 Swift 测试做回归。
      ATK 的真机对拍已经做过（30/30 一致），接入后只需重跑 `core/scripts/test-all.sh --hw`。
      **注意**：接入时设备过滤要换成 `battbar_atk_is_macos_candidate`，不要用 Windows 的 per-collection 规则。
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
## P0 · Windows 原生版 / Native Windows App

### 目标

- 原生 Windows 托盘应用，空闲内存目标 **< 40 MB**（争取 < 25 MB）。
- 支持 ATK / VXE / MAD 2.4G、Razer Viper V3 Pro 2.4G、系统蓝牙鼠标。
- 单击托盘图标打开电量面板；托盘 tooltip 显示所有设备。
- 开机启动、低电量通知、刷新间隔、失败保留上次读数。
- 不要求管理员权限，不联网。

### 先要决定的事

- [x] **协议层**：已定 —— 复用 [`core/`](core/README.md) 的 `battbar-core` crate，**不走 FFI**（同语言直接依赖）。
- [x] **Rust 作 UI 技术栈已确定**（2026-10-27）：与核心同语言、内存可控、可在 macOS 上交叉编译检查。
      剩下的只是托盘/弹窗库选型，见下。
- [ ] **托盘库选型**
  - 方案 A：`tray-icon` + 自绘 Win32 弹窗（egui / 手写 GDI），体积小，样式完全可控。
  - 方案 B：`tao` + `wry`（WebView2），UI 开发快，但会多一个 WebView 进程，内存不达标风险高。
  - 方案 C：直接 `windows` crate 调 Win32 API，最小依赖、最低内存，但代码量最大。
  - 建议：先做 2 天原型，用 `Get-Process` 实测内存后定；**目标是 < 25 MB，WebView2 方案大概率出局**。
- [ ] **托盘如何显示电量**
  - Windows 通知区域只支持图标，不支持 macOS 这种“名称 + 电量”文本。
  - 推荐：托盘图标绘制电量数字/圆环；tooltip 列出 `名称：电量`；点击打开面板显示完整列表。
  - 备选：始终置顶的小悬浮条（可能影响游戏/全屏，默认关闭）。
  - 注意：16×16 图标放不下 3 位数字 + 颜色，需要 32px 高清资源并做 Per-Monitor DPI。
- [ ] **全屏时是否隐藏**
  - Windows 任务栏本身通常会自动隐藏；是否隐藏托盘图标需要产品决策。
  - 如实现：检测前台窗口覆盖显示器 + 任务栏自动隐藏状态，再隐藏图标；退出全屏恢复。
- [ ] **多设备轮播**
  - 托盘图标每 5.5 秒切换一个设备的电量数字/颜色；tooltip 显示全部。
  - 不使用 macOS 的上下文字动画（Windows 托盘不支持）。

### 实现清单

- [ ] 新建 `windows/` Rust 工程（`cargo` + `windows` crate），依赖 `battbar-core`。
- [ ] 单实例锁：`CreateMutex` + `FindWindow`，重复启动时唤起已有实例的面板。
- [ ] HID 传输层：HIDAPI（`hidapi` crate 或直接 `SetupAPI` + `hid.dll`）；封装枚举、open、write、read、feature report。
- [x] ATK 协议（**已在 `battbar-core` 完成**）
  - [x] VID `0x373B` / `0x3554`，候选过滤（含 interface fallback 与键盘排除）。
  - [x] 17 字节写入（report ID `0x08` + 16 字节 payload）。
  - [x] 解析 battery/charging，自动兼容带/不带 report ID 的读缓冲。
  - [ ] **真机待测**：Windows HIDAPI 的 read 缓冲到底含不含 report ID。
- [x] Razer 协议（**已在 `battbar-core` 完成**）
  - [x] VID `0x1532`，PID `0x00C1` / `0x00B3`。
  - [x] 90 字节 feature report、CRC、事务 `0x1F`、电量/充电命令。
  - [x] 91 字节（带前导 report ID）响应自动兼容。
  - [ ] **真机待测**：`hid_send_feature_report` 用 90 还是 91 字节写入能被接收器接受。
- [x] Bluetooth 规则（**已在 `battbar-core` 完成**）
  - [x] PnP 行校验：present 过滤、0–100 范围、鼠标识别。
  - [ ] 传输层仍需实现：SetupAPI 读 `{104EA319-...} 2` 电池属性，或 WinRT `Windows.Devices.Bluetooth`。
  - [ ] 记录哪些鼠标型号暴露 battery 属性。
- [x] 低电量判定（**已在 `battbar-core` 完成**）：20% / 10% 去重、充电后重新武装。
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
- [ ] 品牌迁移后重新授权：确认 `com.battbar.app` 的通知权限、开机启动会重新注册。
- [ ] 英文 UI 本地化（当前面板文案为中文）。
- [x] 品牌统一：`BattBar.app` / `com.battbar.app` / `BattBar-*` 产物 / 文档与代码全部更新，旧 Electron 版同步改名（2026-10-27）。
- [ ] Developer ID 签名 + 公证（需要 Apple Developer 账号）。
- [x] GitHub Actions：`ci.yml` 改为手动触发（macOS 原生测试/构建/打包 + Windows 旧版测试/构建）；`release.yml` 仅在 tag 发布 DMG/ZIP/EXE + SHA256 + GitHub Release。

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
- [协议核心 core/](core/README.md)
- [ATK 协议](docs/atk-protocol.md)
- [Razer 协议](docs/razer-protocol.md)
- [HID 验证探针](tools/hid-probe.js)

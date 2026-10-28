# BattBar · 电量栏

**无线鼠标电量，一眼看清。**
English: [README.en.md](README.en.md) · 待办与验证清单：[TODO.md](TODO.md)

BattBar 是一个常驻菜单栏 / 系统托盘的无线外设电量工具，当前先支持鼠标。当前 macOS 版已经重写为原生 Swift/AppKit 应用：不启动 Electron、不占 GPU、不常驻网络进程，空闲内存约 **14 MB**。

**名字**：Batt（battery，电量）+ Bar（菜单栏 / 任务栏）；中文名「电量栏」。不限定设备类型，以后接键盘、耳机、手柄也不用改名。

> macOS 应用文件、bundle ID、DMG / ZIP / EXE 与仓库统一使用 **BattBar**；界面和中文文案使用「电量栏」。Windows 原生版正在开发中。

<img src="docs/native-panel.png" width="744" alt="BattBar 原生面板">

<img src="docs/native-menubar.png" width="690" alt="菜单栏显示效果">

## 现在能做什么

- **菜单栏直接显示名称 + 电量**：例如 `ATK 无线鼠标 ● 67%`，颜色随电量变化。
- **长名字自动左右滚动**：名称超出菜单栏可用宽度时以 24 pt/s 跑马灯展示；短名字不滚动。
- **多设备上下轮播**：同时发现多个鼠标时，菜单栏每 5.5 秒上下切换一台；也可以在面板里选择设备。
- **其他 App 全屏时自动隐藏**：检测到全屏窗口时隐藏菜单栏项、暂停轮询；退出全屏后自动恢复。
- **ATK / VXE / MAD 2.4G 直读**：通过 Compx HID 协议读取，不依赖 ATK HUB。
- **Razer Viper V3 Pro 2.4G**：按 OpenRazer 的 90 字节 feature report 协议实现，**当前为实验性，等待真机回归**。
- **系统蓝牙鼠标**：读取 macOS 已维护的蓝牙设备电量，不发起蓝牙扫描。
- **低电量提醒**：20% 和 10% 各通知一次；充电或回到 25% 以上后自动重置。
- **等待唤醒**：接收器暂时没有响应时保留上一次读数，并标成 `~67%`，鼠标唤醒后自动更新。
- **本地优先**：没有网络请求，电量数据不离开本机。

## 验证状态

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| ATK 2.4G | ✅ 已真机验证 | ATK 1K 接收器读到 100%（充电中） |
| Razer Viper V3 Pro 2.4G | ⚠️ 代码完成，待真机验证 | 设备不在手边，见 [TODO](TODO.md#p0-razer-viper-v3-pro-24g-真机验证) |
| 系统蓝牙鼠标 | ⚠️ 代码完成，待真机验证 | 解析有样例测试，暂无蓝牙鼠标回归 |
| 菜单栏名称 + 电量 | ✅ 已实现并运行 | 自检读到 100% |
| 长名称左右滚动 | ✅ 实现 + 模拟验证 | 超长名称触发溢出，滚动位移正常 |
| 多设备纵向轮播 | ✅ 实现 + 组件验证 | 索引切换、过渡动画正常；待真实多设备回归 |
| 全屏时隐藏 | ✅ 实现 + 模拟验证 | 覆盖全屏测试窗口可触发隐藏/恢复 |
| 低内存 / 低 CPU | ✅ 已实测 | 空闲约 14 MB，CPU 接近 0 |
| 打包 / 文档 | ✅ 已完成 | DMG / ZIP / SHA256 / 双语文档 |

## 性能

在 Apple M4 Mac mini / macOS 27.0.1 上实测（`footprint` 的 `phys_footprint`，
让应用通过真实面板连续开合 30 次采样）：

| 状态 | 内存占用（footprint） |
| --- | --- |
| 菜单栏常驻、从未打开面板 | 约 14 MB |
| 面板打开时 | 峰值约 95–127 MB |
| 面板关闭后 | 约 36–38 MB，此后不再增长（30 次开合无漂移） |

面板打开时的高占用几乎全部是图形缓冲，不是对象泄漏——分类拆解显示
`Owned physical footprint (graphics)` 约 66 MB、`IOSurface` 约 13 MB、`Malloc Small` 约 18 MB。
关闭后图形缓冲大部分归还，但 SwiftUI/AppKit 会保留一部分，因此回不到 14 MB；
这个值在第一次打开面板后就会稳定下来，不会随使用次数累积。

对比旧 Electron 版本（主进程 + GPU + 网络 + 渲染进程）约 163 MB，原生版仍低约 77%–91%，
且 CPU 空闲时接近 0，不会像 Electron 一样常驻多个进程。

省电策略：

- HID 电量查询按设置的间隔执行（30 秒 / 1 分钟 / 2 分钟 / 5 分钟），一次读取通常几十毫秒。
- 蓝牙信息缓存 120 秒，避免频繁启动 `system_profiler`。
- 只有长名称滚动或多设备切换动画时才有 30 fps 定时器；静止时没有动画定时器。
- 面板打开、其他 App 全屏、屏幕休眠、锁屏时暂停轮询和动画。

重新测量（需要真实接收器，会真实弹出面板）：

```bash
BATTBAR_PANEL_CYCLES=12 "macos/build/BattBar.app/Contents/MacOS/BattBar" &
# 用 pid 采样：footprint -p <pid>
```

省电策略：

- HID 电量查询按设置的间隔执行（30 秒 / 1 分钟 / 2 分钟 / 5 分钟），一次读取通常几十毫秒。
- 蓝牙信息缓存 120 秒，避免频繁启动 `system_profiler`。
- 只有长名称滚动或多设备切换动画时才有 30 fps 定时器；静止时没有动画定时器。
- 面板打开、其他 App 全屏、屏幕休眠、锁屏时暂停轮询和动画。

## 直接使用

构建产物位于 `release/`：

- macOS（Universal，Apple Silicon + Intel）：`BattBar-2.4.0-mac-universal.dmg`
- macOS 备用压缩包：`BattBar-2.4.0-mac-universal.zip`
- Windows（x64，旧 Electron 版）：`BattBar-2.4.0-win-x64.exe`
- 校验文件：`SHA256SUMS.txt`

macOS 包内应用名为 `BattBar.app`，在 Finder 中显示为 **BattBar**；下载后拖入「应用程序」即可。

首次打开未签名的 macOS 应用时，请在 Finder 中右键点击应用，选择「打开」。如果仍被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine "/Applications/BattBar.app"
```

Windows 安装包没有购买代码签名证书，SmartScreen 可能提示「未知发布者」；选择「更多信息 → 仍要运行」即可。

校验：

```bash
cd release && shasum -a 256 -c SHA256SUMS.txt
# Windows PowerShell 可用 Get-FileHash 对照 SHA256SUMS.txt
```

### 首次连接

1. 把接收器插到 USB 口，鼠标切到 **2.4G 模式**。
2. 动一下鼠标，确保它处于唤醒状态。
3. 打开 BattBar，电量会自动出现。
4. 如果 ATK HUB / 雷云正在独占接收器，请先退出它们，再点「重新读取」。

蓝牙鼠标：先在系统设置里完成配对并保持连接，无需额外操作。

## 支持范围

| 设备 | 连接方式 | 读取方式 | 状态 |
| --- | --- | --- | --- |
| ATK / VXE / MAD | 2.4G 接收器 | Compx HID report 8 | 已适配，ATK 1K 真机验证 |
| Razer Viper V3 Pro | 2.4G 接收器 / HyperPolling dongle | Razer 90 字节 feature report | 已实现，实验性，待真机验证 |
| 其他品牌蓝牙鼠标 | 蓝牙 | macOS `system_profiler` | 已实现，取决于系统是否报告电量 |
| 其他品牌 2.4G 鼠标 | 2.4G 接收器 | — | 需要逐个品牌增加 HID 适配器 |

已验证设备：

- `ATK Mouse 1K Dongle`，VID `0x373B` / PID `0x101A`，读取结果 100%（充电中）。
- ATK 接收器不返回鼠标具体型号，因此显示为「ATK 无线鼠标」；蓝牙连接时会显示系统提供的名称。

Razer 目标设备：

- Viper V3 Pro 无线 PID `0x00C1`；HyperPolling 无线接收器 PID `0x00B3`（VID 均为 `0x1532`）。
- 代码路径、事务 ID、CRC、电量/充电命令均已按 OpenRazer 源码核对；因为手头没有真机，暂标记为实验性。
- 插上雷蛇接收器后，面板会尝试自动识别；如果读到电量，会显示为「Razer Viper V3 Pro」或「Razer 无线鼠标」。
- 排查时可运行 `"/Applications/BattBar.app/Contents/MacOS/BattBar" --probe` 查看原始识别结果。

## 如何支持更多设备

代码按「设备提供者（provider）」拆分，UI 和调度不关心品牌：

```text
Sources/Providers/
  Models.swift             设备模型、电量文本、优先级
  ProviderProtocol.swift   DeviceProvider 协议
  HIDSupport.swift         IOHIDManager 枚举
  ATKProtocol.swift        ATK 封包 / 校验 / 解析
  ATKProvider.swift        ATK 接收器发现与读取
  RazerProtocol.swift      Razer 封包 / CRC / 解析
  RazerProvider.swift      Razer 电量与充电状态
  BluetoothProvider.swift  系统蓝牙鼠标
```

新增一个 2.4G 品牌通常只需要：

1. 找到接收器的 VID / PID、厂商 HID collection 和 report descriptor。
2. 在 `XxxProtocol.swift` 里实现请求封包、校验和应答解析（纯数据逻辑，可单测）。
3. 在 `XxxProvider.swift` 里枚举设备、写入查询、等待应答，转换成 `MouseDevice`。
4. 在 `Scanner` 的 HID provider 列表里注册；面板、菜单栏、通知自动复用。

协议细节：

- [ATK / Compx 协议](docs/atk-protocol.md)
- [Razer 协议](docs/razer-protocol.md)

### 硬件验证工具

不依赖原生 App 的跨平台 HID 探针（Windows / macOS / Linux，需要 Node.js 24；CI 与 Windows 旧版构建也使用 24）：

```bash
npm install
npm run probe:hid      # 枚举 VID/PID/usage/report descriptor
npm run probe:atk      # 发送 ATK report 8，打印原始应答和电量
npm run probe:razer    # 发送 Razer 90 字节 feature report，打印原始应答
```

源码在 [tools/hid-probe.js](tools/hid-probe.js)。详细步骤和失败排查见 [TODO.md](TODO.md)。

### 三平台路线

当前阶段的优先级很明确：

1. **先把 macOS 原生版打磨到可日常使用**（当前）：低内存、ATK / Razer / 蓝牙、菜单栏滚动与全屏隐藏、DMG 发布。
2. **再做 Windows 原生版**：HIDAPI 传输层 + 原生托盘 UI；现有 Electron 版先作为过渡。

目标是 macOS 与 Windows 两个平台，**UI 按平台落地，协议核心共用一份 Rust 实现**（Linux 不在计划内）：

| 平台 | UI | HID 传输 | 协议核心 | 状态 |
| --- | --- | --- | --- | --- |
| macOS | Swift + AppKit | IOKit `IOHIDDevice` | `core/`（静态库，经 C ABI 链接） | 当前版本 |
| Windows | C# / .NET 8 + WinForms `NotifyIcon` | SetupAPI + `hid.dll` | `core/`（编译为 `battbar_ffi.dll`，P/Invoke） | 开发中，未真机验证 |

**规则全部在 Rust，Swift 只负责 UI 和系统调用。** 协议、电量判定、设备识别、排序策略、
低电量去重都收拢在 [`core/`](core/README.md)：一份实现，`#![forbid(unsafe_code)]`、零运行时依赖。
macOS 应用通过 C ABI 静态链接它，`CoreBridge.swift` 只做指针搬运，不含任何判断逻辑。
测试向量 `core/vectors/vectors.json` 仍由 Rust / Swift / JavaScript 三方回放
（`core/scripts/test-all.sh`）。

现有 Electron 代码保留，作为 Windows 过渡实现和对照参考，不再作为 macOS 的发布形态。

## 协议核心（Rust）

要求：Rust 1.75+（含 `rustfmt` / `clippy`）。Swift 对拍还需要 macOS + Command Line Tools。

```bash
./core/scripts/test-all.sh      # 全量：fmt / clippy / 单测 / JS 对拍 / Swift 对拍 / FFI 冒烟
cargo test --manifest-path core/Cargo.toml
node core/scripts/crosscheck.mjs
./core/scripts/build-macos.sh   # 产出 core/target/macos/libbattbar_ffi.a 并从 Swift 调用验证
```

`core/vectors/vectors.json` 是协议的单一事实来源，Rust、现有 Swift、现有 JavaScript
三方都用它回放；任何一方行为漂移都会让检查失败。详见 [core/README.md](core/README.md)。

## Windows 开发

要求：Windows 10/11、Rust（含 `x86_64-pc-windows-msvc` 目标）、.NET 8 SDK。

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

脚本会先把 Rust 核心编成 `battbar_ffi.dll`，再发布单文件 `BattBar.exe` 到 `release\win\`。

工程结构（产物在 `windows/BattBar.Windows/`）：

| 文件 | 职责 |
| --- | --- |
| `Program.cs` | 单实例 Mutex、启动 |
| `TrayApplication.cs` | 托盘图标、右键菜单、定时扫描 |
| `Core.cs` / `CoreBridge.cs` | 对 `battbar_ffi.dll` 的 P/Invoke 与编组，**不含判断逻辑** |
| `Hid.cs` | SetupAPI 枚举、重叠 I/O 读写、feature report |
| `Providers.cs` | ATK / Razer 扫描，候选与解码走 DLL |
| `BluetoothScanner.cs` | 注册表 PnP 电池属性 |
| `BatteryIcon.cs` | 图标绘制 |
| `Settings.cs` / `Autostart.cs` | 设置持久化、开机启动 |

**所有协议与判定规则仍在 Rust 核心**；C# 只负责 OS 调用与界面。
当前状态：`dotnet build` 通过，但还没有在真实 Windows 机器上运行过，清单见 [TODO.md](TODO.md#p0-windows-原生版)。

## macOS 开发

要求：macOS 13+、Xcode Command Line Tools（不需要完整 Xcode）。

```bash
cd macos

./scripts/build-native.sh     # 编译 Universal .app
./scripts/test-native.sh      # 协议 / 蓝牙解析 / 设置测试
open build/BattBar.app

./scripts/package-native.sh   # 生成 DMG / ZIP 并刷新 release/SHA256SUMS.txt
```

构建产物：

```text
macos/build/BattBar.app
```

脚本会自动选择可用的 Command Line Tools SDK；如果机器上的 SDK 与编译器不匹配，可以手动指定：

```bash
BATTBAR_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  ./scripts/build-native.sh
```

只编译 Apple Silicon：

```bash
ARCHS=arm64 ./scripts/build-native.sh
```

重新生成 README 顶部的预览图（面板 4x、菜单栏 6x）：

```bash
macos/build/BattBar.app/Contents/MacOS/BattBar --render-preview docs
```

GitHub 把图片按「一个图片像素 = 一个 CSS 像素」显示，Retina 屏上每个 CSS 像素要占两个物理像素，所以 372 pt 的面板要渲染成 4x（1488 px），再在 README 里用 `width="744"` 显示回原来的大小，才能一比一落在屏幕上；按 2x 出图会在大屏上被放大一倍而发虚。

### CI / Release

- `.github/workflows/ci.yml`：不再随 push 自动运行，只在 GitHub Actions 页面手动触发；会跑 macOS 原生测试 / Universal 构建 / DMG / ZIP，以及 Windows 旧 Electron 版测试和安装包构建。
- `.github/workflows/release.yml`：唯一自动构建入口。推送 `v*` tag 时构建 macOS DMG / ZIP、Windows EXE，生成 `SHA256SUMS.txt`，并创建 GitHub Release。
- `release/` 已在 `.gitignore` 中忽略，发布产物通过 GitHub Releases 分发，不提交进仓库。

### 原生版目录

```text
macos/
  BattBar/Sources/
    App/            入口、设置、调度、自检、预览渲染
    MenuBar/        状态栏视图、跑马灯、轮播、全屏检测
    Panel/          SwiftUI 面板、NSPopover 控制器
    Providers/      ATK / Razer / 蓝牙适配器
    Services/       通知、登录项
  BattBar/Tests/
  scripts/
    build-native.sh
    test-native.sh
    package-native.sh
  build/            本地构建产物

tools/
  hid-probe.js      跨平台 HID 硬件验证探针
```

## Windows（旧 Electron 版）

要求 Node.js 24（与 GitHub Actions 一致）。Windows 版本仍使用原来的 Electron 实现，ATK 协议与 macOS 一致；通用蓝牙电量依赖 Windows PnP 电池属性，部分设备可能不暴露。

```bash
npm install
npm start          # 开发模式
npm test           # 旧版 Node 测试
npm run pack:win   # Windows x64 NSIS 安装包
```

Windows 原生版的设计、限制和验证清单见 [TODO.md](TODO.md#p0-windows-原生版)。特别提醒：Windows 通知区域（系统托盘）只支持图标，不支持 macOS 这种名称文本，因此 Windows 版会采用图标电量 / 数字 / 悬浮提示的组合，具体方案待定。

## 已知行为与排查

**ATK / Razer 接收器没有响应**

- 无线鼠标休眠时，接收器可能无法代为读取电量。动一下鼠标后重试。
- 退出 ATK HUB、雷云或其他会打开该 HID 接口的软件。
- 重新插拔接收器，确认它出现在「系统信息 → USB」中。
- 设置 →「复制诊断信息」，日志里会记录最近扫描结果和错误码。
- 仍无法定位时，在终端运行：

```bash
"/Applications/BattBar.app/Contents/MacOS/BattBar" --probe
```

**蓝牙鼠标没有出现**

- 确认它已经在系统设置中显示为「已连接」，而不仅是「已配对」。
- macOS 只筛选鼠标 / pointing 类设备；耳机等其它设备不会显示。
- Windows 设备如果没有暴露 PnP 电池属性，系统本身也不会显示电量。

**菜单栏显示 `~25%`**

这是有意保留的上一次成功读数，数字前的 `~` 表示它不是刚刚读到的。

接收器在鼠标休眠时会漏答查询，所以单次没读到不会立刻变色：只要读数还没超过 2.5 分钟，就仍按正常读数显示；超过之后才标记 `~` 并把电量图标变灰。标记期间每 60 秒重试一次（不受「刷新间隔」限制），鼠标一唤醒就会自动恢复。

**菜单栏项消失了**

如果开启了「全屏应用时隐藏」，其他 App 全屏时状态栏项会隐藏；退出全屏或切换到桌面后恢复。

**低电量通知没有弹出**

- macOS：系统设置 → 通知 →「BattBar」，确认允许通知。
- 首次开启提醒时会请求权限；也可以点「发送测试通知」验证。

## 隐私

- 应用不会发起任何网络请求。
- 不申请蓝牙扫描权限；macOS 读取的是系统已经维护的蓝牙设备信息。
- HID 读取只发送只读电量查询，不写入鼠标配置。
- 设置和诊断信息只保存在本机。

## License

[MIT](LICENSE)

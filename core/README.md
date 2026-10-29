# battbar-core · 平台无关协议核心

**一份协议实现，三套平台 UI。** 这个目录存放 BattBar 所有"把字节变成电量"的逻辑：
ATK / VXE / MAD 2.4G、Razer Viper V3 Pro 2.4G、系统蓝牙电量解析，以及低电量提醒的去重规则。

UI 不属于这里：macOS 是 Swift/AppKit，Windows 待定（Rust 候选）。核心只处理 `&[u8]` 和 `&str`。

```
core/
├── battbar-core/           纯 Rust 逻辑（#![forbid(unsafe_code)]，无运行时依赖）
│   ├── src/atk.rs            ATK 组包 / 校验和 / 解码 / 候选过滤 / 稳定 ID
│   ├── src/razer.rs          Razer 90 字节 feature report / CRC / 电量换算
│   ├── src/bluetooth.rs      macOS 属性选择、Windows PnP 校验、鼠标识别
│   ├── src/battery.rs        百分比归一化与换算
│   ├── src/alerts.rs         低电量 / 临界提醒去重
│   ├── src/retry.rs          掉读数后是否值得再试一次（只给策略，不给定时器）
│   └── tests/vectors.rs      用共享测试向量做的契约测试
├── battbar-ffi/            C ABI（staticlib + cdylib），给 macOS Swift 用
│   ├── include/battbar_core.h
│   └── src/lib.rs
├── vectors/vectors.json    单一事实来源，三方对拍
└── scripts/                构建、对拍、冒烟测试
```

## 为什么这样切

之前 ATK 协议有**三份独立实现**（`macos/.../ATKProtocol.swift`、`electron/providers/atk-protocol.js`、
`tools/hid-probe.js`），校验和公式各写各的，行为已经出现分歧（见下方"已知差异"）。
把协议放进一个可测试的核心里，平台层只负责"开设备、读字节、画界面"。

## 分工：规则全在 Rust，Swift 只剩 UI 与 OS 调用

macOS 应用已经接入：`macos/BattBar/Sources/Core/CoreBridge.swift` 是**唯一**的 FFI 绑定层，
只做指针搬运，不含任何判断逻辑。

| 归 Rust（`core/`） | 归 Swift（`macos/`） |
| --- | --- |
| ATK / Razer 组包、校验和、解码 | IOKit 枚举、打开设备、读写报告 |
| 电量换算、充满/低电量判定 | 菜单栏与面板绘制、动画、文案 |
| 蓝牙属性选择、充电字段解析 | 启动 `system_profiler`、解析它返回的 JSON 结构 |
| 鼠标识别、设备稳定 ID | 构造 `MouseDevice` 模型对象 |
| 设备保留/排序/当前选中策略 | `@Published` 状态、SwiftUI 绑定 |
| 低电量提醒阈值与去重 | 发通知、申请权限、通知文案 |
| ATK 候选设备过滤（IOKit 模型） | 设置持久化、开机启动、全屏检测 |

判断标准很简单：**能写成"给定输入，输出唯一"的规则 → Rust**；**需要调系统 API 或画东西 → Swift**。

## 快速开始

```bash
# 全部检查（Rust + JS 对拍 + Swift 对拍 + FFI 冒烟）
core/scripts/test-all.sh

# 只跑 Rust
cargo test --manifest-path core/Cargo.toml

# JS 现有实现与核心对拍
node core/scripts/crosscheck.mjs

# 已发布的 Swift 实现与核心对拍
core/scripts/crosscheck-swift.sh

# 构建 macOS 静态库并从 Swift 调用（验证 C ABI 可用）
core/scripts/build-macos.sh

# 解码一段抓到的原始报文（真机排查用）
cargo run --manifest-path core/Cargo.toml --example decode-hex -- atk 0804000000025f00100d000000000000cb
```

要求：Rust 1.75+（`rustfmt`、`clippy`）、Node.js 24+；Swift 对拍需要 macOS + Xcode Command Line Tools。

### 用 `decode-hex` 验证真机数据

抓包得到的 hex 可以直接喂给核心，确认"字节 → 电量"的每一步都符合预期：

```text
$ cargo run --example decode-hex -- atk 0804000000025f00100d000000000000cb
input: 17 bytes = 0804000000025f00100d000000000000cb
result: battery=95% charging=false
```

上面这条就是本机 ATK 1K 接收器的真实应答（鼠标电量 95%）。
退出码：`0` 解码成功，`1` 不是该协议的报文，`2` 协议错误（状态码 / 长度 / 命令不匹配），`64` 用法错误。

## 共享测试向量：`vectors/vectors.json`

这是整套设计的关键。同一份 JSON 会被三方回放：

| 消费方 | 入口 |
| --- | --- |
| Rust 核心 | `core/battbar-core/tests/vectors.rs` |
| 现有 JS（Electron + 探针） | `core/scripts/crosscheck.mjs` |
| 已发布的 Swift 应用 | `core/scripts/crosscheck-swift.sh` |
| 真机（可选） | `core/scripts/hardware-test-macos.sh` |

任何一方行为漂移都会让 CI 变红。每个用例可以带 `targets` 字段，声明它要求哪些实现一致；
**没有 `targets` 表示三方必须完全一致**。

### 当前对拍结果

```
cargo test         67 passed （49 单元 + 12 向量契约 + 6 C ABI）
JS cross-check     40 passed, 0 failed, 3 skipped
Swift cross-check  45 checks, 0 failed, 1 skipped
FFI smoke test     ok
真机（有硬件时）   21 checks, 0 failed
```

## 已知差异（有意为之）

这些是 `targets` 字段标注出来的、**核心已修正但旧实现仍保留**的行为：

| 场景 | 旧实现 | 核心 | 说明 |
| --- | --- | --- | --- |
| ATK 响应不足 9 字节 | Electron 直接丢弃 | 按 7 字节有效载荷解析 | Electron 的错误分支要求 `length >= 9`，导致短应答被当成"继续等待" |
| ATK 短包里的非零状态码 | Electron 静默丢弃（等到超时） | 立即返回 `Status(n)` | 用户能看到"设备返回状态 0x??"而不是 3 秒超时 |
| 蓝牙 `-5%` | Electron 正则取到 `5` | 拒绝 | 负数被误读成正数是真 bug |
| Razer 91 字节响应 | Swift 不处理，读到错位的字节 | 自动剥掉前导 report id | `TODO.md` 第 6 类失败排查项 |

上表前三项在 JS 对拍里会显示为 `skipped`；第四项在 Swift 对拍里显示为 `1 skipped`。
**Windows 版与后续重构一律以核心行为为准**，旧实现只作为兼容参考。

## 真机验证（2026-10-27，ATK 1K 接收器）

`core/scripts/hardware-test-macos.sh` 会从真实接收器读报文，同时用**已发布的 Swift 实现**和
**Rust 核心**解码，再逐项比对。这是单元测试覆盖不到的那一层。

```bash
core/scripts/test-all.sh --hw     # 全量 + 真机
core/scripts/hardware-test-macos.sh
BATTBAR_HW_ITERATIONS=30 core/scripts/hardware-test-macos.sh
```

实测结果：

| 项目 | 结果 |
| --- | --- |
| ATK 连续读取 | **30/30 成功**，超时 0 次，每次 21–26 ms |
| 核心 vs Swift 解码 | 30 次全部一致（电量与充电状态） |
| 请求字节 | 核心与 Swift 完全相同（`…0049`） |
| 读数稳定性 | 短时间内保持 95%，无抖动 |
| 核心选中的设备 | 与 Swift 选中同一个（`page=0xFF05`） |
| 真机检查项 | 21 项，0 失败 |
| 已发布 App 的 `--self-test` | PASS（设备 1 台、面板正常打开与关闭） |

Razer 与蓝牙**无法在本次验证**：本机没有 Razer 接收器，也没有连接蓝牙鼠标。两者仍是未验证项。

### 顺带发现：枚举 API 不同，不是操作系统不同

我最初把这件事写成"macOS 与 Windows 的差异"，**那是错的**。查 hidapi 源码后确认：

- `hidapi/mac/hid.c` 的 `create_device_info()` 拿到 IOKit 的**每设备**结果后，会按 usage pair
  **自己展开**成多条（`create_device_info_with_usage`）。本机实测：3 个设备 → 11 条记录。
- `hidapi/windows/hid.c` 的 `hid_enumerate()` 用 `CM_Get_Device_Interface_ListW` 枚举
  **device interface**，本身就是按 collection 的。

所以准确说法是：

| 枚举方式 | 粒度 | 谁在用 |
| --- | --- | --- |
| hidapi（`node-hid`、Rust `hidapi` crate） | 每个 **collection** 一条 | Electron（macOS/Windows 都是）、未来的 Windows 原生版 |
| 裸 IOKit `IOHIDManagerCopyDevices` | 每个 **设备** 一条，只给 primary usage page | 现在的 Swift 应用 |

两者在 **macOS 上同时存在**，本机都实测过（11 条 vs 3 条）。核心因此保留两套规则，
选哪个取决于**调用方用的是哪个 API**，而不是跑在哪个系统上：

- `atk::find_candidates` — per-collection 模型，优先 `0xFF04/0x02`
- `atk::find_macos_candidates` / `battbar_atk_is_macos_candidate` — per-device 模型，
  按 vendor usage page 范围 `0xFF00..=0xFFFF` 判断

两张真实设备表已写入 `vectors/vectors.json`（`atk.devices`、`atk.macos_devices`），并有一个
不变式测试断言"按 path 分组后两边描述的是同一批物理设备"。

## C ABI

macOS 侧用静态库，bundle 保持单文件：

```bash
core/scripts/build-macos.sh            # 主机架构，产出 core/target/macos/libbattbar_ffi.a
core/scripts/build-macos.sh universal  # arm64 + x86_64，lipo 合并
```

Swift 里通过 bridging header 引入 `core/battbar-ffi/include/battbar_core.h`：

```swift
var request = [UInt8](repeating: 0, count: Int(battbar_atk_request_len()))
_ = request.withUnsafeMutableBufferPointer {
    battbar_atk_request($0.baseAddress, $0.count)
}

var reading = BattbarReading(battery: 0, charging: 0)
let status = bytes.withUnsafeBufferPointer {
    battbar_atk_decode(0x08, $0.baseAddress, $0.count, &reading)
}
// status == 1  OK
// status == 0  不是 ATK 报文，继续读
// status < 0   见 battbar_core.h 的错误码
```

约定：返回值非负为成功（通常是字节数或百分比），负数为错误码；所有指针参数都做空指针与容量检查；
**不会有 panic 穿过 C 边界**（release 配置为 `panic = "abort"`）。

## 设计约束

- **核心零依赖**：`battbar-core` 没有运行时依赖，只有 `serde_json` 作为 dev-dependency 用于读测试向量。
- **核心无 `unsafe`**：`#![forbid(unsafe_code)]`，`unsafe` 只允许出现在 `battbar-ffi`。
- **核心不含 UI 文案**：`alerts` 返回结构化的 `AlertKind`，标题/正文由平台层按语言本地化。
- **平台层不含协议**：枚举、打开、读写、超时属于平台；解码、换算、去重属于核心。

## 与 Windows 版的关系

Windows UI 用 Rust，**直接依赖 `battbar-core` crate，不走 FFI**（同语言不需要中间层）。
Windows 独占的部分——托盘图标、`TrackPopupMenu`、SetupAPI/PnP 属性读取、HIDAPI 传输——放在
`windows/` 下，等待技术选型定稿（见 `TODO.md`）。

`cargo check --target x86_64-pc-windows-msvc` 在 macOS 上已验证可以通过，CI 的
`core-windows` job 负责在真实 Windows runner 上编译。本地想复现需要先装目标：

```bash
rustup target add x86_64-pc-windows-msvc
cargo check --manifest-path core/Cargo.toml --target x86_64-pc-windows-msvc --workspace --all-targets
```

只做类型检查不需要 Windows SDK 或链接器；产出真正的 `.exe/.dll` 才需要，那一步交给 CI。
`battbar-ffi` 同时产出 `cdylib`，因此将来若有非 Rust 的 Windows UI，也可以直接 `.dll` 接入。

## 后续步骤

1. ~~macOS 版接入核心~~ 已完成（2026-10-27）：`ATKProtocol` / `RazerProtocol` 改为 FFI 调用，
   现有 Swift 测试作为回归，真机 21 项检查通过。
2. 蓝牙规则仍留在 Swift（`BluetoothProvider`）。它只处理系统给的 JSON 结构，属于平台层职责，
   与核心的差异由 `crosscheck.mjs` 与 `tests/vectors.rs` 守着；如果要彻底统一，需要给
   `battbar-core::bluetooth` 加一组 key/value 的 C ABI。
3. Windows 原生版落地，直接使用 crate。
4. 三平台都跑在核心之上后，删除 Electron 与探针里的重复协议实现。

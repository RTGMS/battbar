import SwiftUI

struct PanelActions {
    var refresh: () -> Void
    var selectDevice: (String) -> Void
    var setRefreshInterval: (Int) -> Void
    var setLowBatteryAlerts: (Bool) -> Void
    var setHideWhenFullscreen: (Bool) -> Void
    var setLaunchAtLogin: (Bool) -> Void
    var copyDiagnostics: () -> Void
    var testNotification: () -> Void
    var quit: () -> Void
}

enum Theme {
    static let mint = Color(red: 0.61, green: 0.91, blue: 0.72)
    static let mintBright = Color(red: 0.80, green: 1.0, blue: 0.87)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.44)
    static let coral = Color(red: 1.0, green: 0.60, blue: 0.54)
    static let teal = Color(red: 0.55, green: 0.91, blue: 0.83)
    static let text = Color(red: 0.95, green: 0.97, blue: 0.95)
    static let muted = Color(red: 0.55, green: 0.62, blue: 0.58)
    static let faint = Color(red: 0.39, green: 0.46, blue: 0.41)
    static let card = Color.white.opacity(0.035)
    static let line = Color.white.opacity(0.075)
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if showingSettings {
                    settings
                } else {
                    dashboard
                }
            }
            footer
        }
        .frame(width: 372, height: 600)
        .background(background)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.105, blue: 0.078),
                    Color(red: 0.025, green: 0.050, blue: 0.038),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [Color(red: 0.18, green: 0.42, blue: 0.28).opacity(0.16), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                Image(systemName: "computermouse")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("电量栏")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("BATTBAR")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 8)

            if showingSettings {
                headerButton("chevron.left", help: "返回") {
                    showingSettings = false
                }
            } else {
                headerButton("gearshape", help: "设置") {
                    showingSettings = true
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(height: 58)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 27, height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var dashboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                if let device = model.activeDevice {
                    deviceHeading(device)
                    hero(device)
                    metrics(device)
                    refreshRow(device)
                    if model.devices.count > 1 {
                        deviceList
                    }
                    if !model.issues.isEmpty {
                        issueBanner
                    }
                    supportCard
                } else if model.isScanning {
                    loadingState
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 5)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func deviceHeading(_ device: MouseDevice) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("当前鼠标")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(Theme.faint)
                Text(device.name)
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(device.connectionLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.77, green: 0.82, blue: 0.78))
            }
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Capsule().fill(Color.white.opacity(0.045)))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
    }

    private func hero(_ device: MouseDevice) -> some View {
        HStack(spacing: 2) {
            gauge(device)
            VStack(alignment: .leading, spacing: 0) {
                Text(status(for: device).kicker)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.13)))
                Text(status(for: device).headline)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.35)
                    .foregroundStyle(Theme.text)
                    .padding(.top, 10)
                Text(status(for: device).message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                HStack(spacing: 6) {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 12, height: 1)
                    Text("\(device.source) · \(device.connectionLabel)")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                .padding(.top, 12)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 10)
        }
        .padding(.horizontal, 8)
        .frame(height: 220)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.22, blue: 0.17),
                                Color(red: 0.035, green: 0.075, blue: 0.055),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RadialGradient(
                    colors: [accent.opacity(0.16), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: 230
                )
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                Image(systemName: "computermouse")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.028))
                    .rotationEffect(.degrees(11))
                    .offset(x: 135, y: 30)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func gauge(_ device: MouseDevice) -> some View {
        let fraction = CGFloat(device.battery ?? 0) / 100
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.075), lineWidth: 5)
                .frame(width: 132, height: 132)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(
                    AngularGradient(
                        colors: [accent.opacity(0.55), accent],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 132, height: 132)
                .shadow(color: accent.opacity(0.3), radius: 4)
                .animation(.easeOut(duration: 0.55), value: fraction)
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [1.2, 7]))
                .foregroundStyle(Color.white.opacity(0.12))
                .frame(width: 151, height: 151)
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(device.battery.map(String.init) ?? "--")
                        .font(.system(size: 45, weight: .medium))
                        .tracking(-2.2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                Text(device.isStale ? "上次读数" : "剩余电量")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 155, height: 175)
    }

    private func metrics(_ device: MouseDevice) -> some View {
        HStack(spacing: 0) {
            metric("连接方式", device.connectionLabel)
            Divider().overlay(Theme.line)
            metric("电源状态", device.isStale ? "等待响应" : (device.charging == true ? "充电中" : (device.charging == false ? "使用中" : "未知")))
            Divider().overlay(Theme.line)
            metric("数据来源", device.source)
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func refreshRow(_ device: MouseDevice) -> some View {
        HStack {
            Text(updatedText(device))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.faint)
            Spacer()
            Button(action: actions.refresh) {
                HStack(spacing: 5) {
                    if model.isScanning {
                        ProgressView().controlSize(.mini).tint(Theme.muted)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(model.isScanning ? "读取中" : "重新读取")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
        }
        .padding(.top, 1)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("已发现的设备")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("\(model.devices.count)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
            }
            ForEach(model.devices) { device in
                Button {
                    actions.selectDevice(device.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "computermouse")
                            .font(.system(size: 13))
                            .foregroundStyle(device.id == model.activeDevice?.id ? accent : Theme.muted)
                            .frame(width: 27, height: 27)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                                .lineLimit(1)
                            Text(device.isStale ? "等待响应 · \(device.connectionLabel)" : "\(device.connectionLabel) · \(device.source)")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        batteryPill(device)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 45)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(device.id == model.activeDevice?.id ? accent.opacity(0.12) : Color.white.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(device.id == model.activeDevice?.id ? Color.white.opacity(0.06) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 3)
    }

    private func batteryPill(_ device: MouseDevice) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 33, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(deviceColor(device))
                        .frame(width: max(3, 33 * CGFloat(device.battery ?? 0) / 100), height: 3)
                }
            Text(device.batteryText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("设备支持")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("协议适配器架构")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
            HStack(spacing: 5) {
                supportChip("ATK / VXE 2.4G", color: Theme.mint)
                supportChip("Razer 2.4G · 实验性", color: Theme.amber)
                supportChip("系统蓝牙", color: Theme.teal)
            }
            Text("后续会加入 Windows / Linux 版本，并按品牌扩展更多 HID 适配器。")
                .font(.system(size: 8))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .padding(.top, 2)
    }

    private func supportChip(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 8))
                .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.8))
    }

    private var issueBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.issues.first?.message ?? "读取提示")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.92, green: 0.78, blue: 0.57))
                if let detail = model.issues.first?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber.opacity(0.15), lineWidth: 1))
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(accent)
            Text("正在读取鼠标电量")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("ATK / Razer 接收器与系统蓝牙鼠标会自动识别")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    .foregroundStyle(Color.white.opacity(0.11))
                    .frame(width: 128, height: 128)
                Image(systemName: "computermouse")
                    .font(.system(size: 55, weight: .ultraLight))
                    .foregroundStyle(Theme.muted.opacity(0.8))
            }
            .padding(.bottom, 4)
            Text("没有找到鼠标")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("请确认接收器已插好，或在系统设置中连接蓝牙鼠标。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button(action: actions.refresh) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新扫描")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.13, blue: 0.09))
                .padding(.horizontal, 15)
                .frame(height: 33)
                .background(RoundedRectangle(cornerRadius: 10).fill(accent))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            if !model.issues.isEmpty {
                issueBanner
                    .frame(maxWidth: 300)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 450)
    }

    private var settings: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("偏好设置")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(Theme.faint)
                    Text("让它更合你意")
                        .font(.system(size: 21, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.text)
                }
                .padding(.top, 2)

                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("刷新频率")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                            Spacer()
                            Text("自动读取电量")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Theme.faint)
                        }
                        HStack(spacing: 2) {
                            ForEach([30, 60, 120, 300], id: \.self) { interval in
                                Button {
                                    actions.setRefreshInterval(interval)
                                } label: {
                                    Text(intervalLabel(interval))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(model.settings.refreshInterval == interval ? Theme.text : Theme.muted)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 27)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7)
                                                .fill(model.settings.refreshInterval == interval ? Color.white.opacity(0.075) : .clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
                    }
                }

                settingsCard {
                    VStack(spacing: 0) {
                        settingsToggle(
                            title: "低电量提醒",
                            subtitle: "电量降至 20% 和 10% 时通知",
                            isOn: model.settings.lowBatteryAlerts,
                            action: actions.setLowBatteryAlerts
                        )
                        Divider().overlay(Theme.line).padding(.vertical, 9)
                        settingsToggle(
                            title: "全屏应用时隐藏",
                            subtitle: "其他 App 全屏时自动隐藏菜单栏文字",
                            isOn: model.settings.hideWhenFullscreen,
                            action: actions.setHideWhenFullscreen
                        )
                        Divider().overlay(Theme.line).padding(.vertical, 9)
                        settingsToggle(
                            title: "开机自动启动",
                            subtitle: "登录后安静地待在菜单栏",
                            isOn: model.settings.launchAtLogin,
                            action: actions.setLaunchAtLogin
                        )
                    }
                }

                settingsCard {
                    VStack(spacing: 3) {
                        settingsAction("ladybug", title: "复制诊断信息", subtitle: "用于排查读取问题", action: actions.copyDiagnostics)
                        Divider().overlay(Theme.line).padding(.leading, 34)
                        settingsAction("bell.badge", title: "发送测试通知", subtitle: "验证系统通知权限", action: actions.testNotification)
                    }
                }

                if let message = model.settingsMessage {
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(0.045))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
                        Image(systemName: "computermouse")
                            .font(.system(size: 17))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 33, height: 33)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("电量栏 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1") · 原生版")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                        Text("ATK 2.4G 已适配；Razer 支持实验性接入，蓝牙鼠标通过系统读取。")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text("LOCAL")
                        .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.12)))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.line, lineWidth: 1))

                Button(action: actions.quit) {
                    Text("退出电量栏")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.86, green: 0.60, blue: 0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 33)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.red.opacity(0.055)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.red.opacity(0.11), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Text("电量数据仅在本机读取，不会上传到任何服务器。")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 5)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }

    private func settingsToggle(
        title: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                Text(subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
                .controlSize(.small)
        }
    }

    private func settingsAction(_ symbol: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.79))
                    Text(subtitle)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isScanning ? Theme.amber : accent)
                .frame(width: 4, height: 4)
            Text(model.isScanning ? "正在读取电量…" : model.autoRefreshText)
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.faint)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9))
                Text("仅本机读取")
                    .font(.system(size: 8.5))
            }
            .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18)
        .frame(height: 39)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
        }
    }

    private var accent: Color {
        color(for: model.activeDevice)
    }

    private func color(for device: MouseDevice?) -> Color {
        guard let device, let battery = device.battery else { return Theme.mint }
        if device.charging == true { return Theme.teal }
        if battery <= 20 { return Theme.coral }
        if battery <= 40 { return Theme.amber }
        return Theme.mint
    }

    private func deviceColor(_ device: MouseDevice) -> Color {
        color(for: device)
    }

    private func status(for device: MouseDevice) -> (kicker: String, headline: String, message: String) {
        guard let battery = device.battery else {
            return ("等待数据", "暂时没有读数", "设备已连接，但还没有拿到有效的电量数据。")
        }
        if device.isStale {
            return ("等待唤醒", "保持上次读数", "接收器暂时没有响应，唤醒鼠标后会自动更新。")
        }
        if device.charging == true {
            if battery >= 100 {
                return ("已充满", "能量满格", "电池已经充满，可以拔掉线继续使用。")
            }
            return ("正在充电", "电量回升中", "接收器正在为鼠标补能，可以安心继续使用。")
        }
        if battery <= 10 {
            return ("需要注意", "电量告急", "建议立即充电，避免关键操作时突然掉线。")
        }
        if battery <= 20 {
            return ("低电量", "电量偏低", "建议尽快充电，别让关键一局没电。")
        }
        if battery <= 40 {
            return ("还可再战", "电量不多", "已接近低电量，建议尽快找个时间补电。")
        }
        if battery <= 70 {
            return ("状态稳定", "状态良好", "电量健康，放心继续使用。")
        }
        return ("能量充沛", "电量充足", "电量充足，随时可以开一局。")
    }

    private func updatedText(_ device: MouseDevice) -> String {
        if device.isStale {
            return "上次读取 \(timeString(device.lastSeen))"
        }
        guard let lastUpdated = model.lastUpdated else { return "尚未读取" }
        let seconds = max(0, Int(Date().timeIntervalSince(lastUpdated)))
        if seconds < 10 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        return "\(timeString(lastUpdated)) 更新"
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func intervalLabel(_ interval: Int) -> String {
        switch interval {
        case 30: return "30 秒"
        case 120: return "2 分钟"
        case 300: return "5 分钟"
        default: return "1 分钟"
        }
    }
}

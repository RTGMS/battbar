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
    static let volt = Color(red: 0.78, green: 0.96, blue: 0.43)
    static let voltSoft = Color(red: 0.93, green: 1.0, blue: 0.77)
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.38)
    static let teal = Color(red: 0.42, green: 0.90, blue: 0.84)
    static let text = Color(red: 0.95, green: 0.97, blue: 0.93)
    static let muted = Color(red: 0.62, green: 0.68, blue: 0.63)
    static let faint = Color(red: 0.38, green: 0.44, blue: 0.40)
    static let card = Color.white.opacity(0.038)
    static let line = Color.white.opacity(0.08)
}

/// A small battery silhouette with three charge bars inside. It also doubles as
/// the BattBar wordmark, so the icon and the brand stay recognisable at 16 pt.
struct BattBarMark: View {
    var color: Color

    var body: some View {
        HStack(spacing: 1.8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                    .stroke(color, lineWidth: 1.3)
                    .frame(width: 16, height: 10)
                HStack(alignment: .bottom, spacing: 1.1) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.7)
                            .fill(color.opacity(index == 2 ? 0.55 : 1))
                            .frame(width: 2, height: CGFloat(2 + index * 2))
                    }
                }
                .padding(.leading, 2)
                .frame(width: 13, height: 7, alignment: .bottomLeading)
            }
            RoundedRectangle(cornerRadius: 0.9)
                .fill(color.opacity(0.75))
                .frame(width: 1.8, height: 4)
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions
    @State private var showingSettings: Bool

    init(model: AppModel, actions: PanelActions, initiallyShowingSettings: Bool = false) {
        self.model = model
        self.actions = actions
        _showingSettings = State(initialValue: initiallyShowingSettings)
    }

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
        .frame(width: 372, height: 560)
        .background(background)
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.066, blue: 0.055),
                    Color(red: 0.012, green: 0.016, blue: 0.013),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.15), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 330
            )
            RadialGradient(
                colors: [Color(red: 0.34, green: 0.44, blue: 0.20).opacity(0.08), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    )
                BattBarMark(color: accent)
            }
            .frame(width: 29, height: 29)

            VStack(alignment: .leading, spacing: 2) {
                Text("BattBar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Theme.text)
                Text("电量栏 · BATTERY MONITOR")
                    .font(.system(size: 6.8, weight: .medium, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 8)

            headerButton(showingSettings ? "chevron.left" : "gearshape", help: showingSettings ? "返回" : "设置") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingSettings.toggle()
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
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.line, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
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
                    supportLine
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
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 2.5, height: 31)

            VStack(alignment: .leading, spacing: 3) {
                Text("当前设备")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.9)
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
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.text.opacity(0.8))
            }
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Capsule().fill(Color.white.opacity(0.045)))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .frame(height: 44)
    }

    private func hero(_ device: MouseDevice) -> some View {
        let status = status(for: device)
        let fraction = CGFloat(device.battery ?? 0) / 100

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(device.battery.map(String.init) ?? "--")
                            .font(.system(size: 58, weight: .semibold, design: .rounded))
                            .tracking(-2.4)
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        Text("%")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(device.isStale ? "上次读数" : "剩余电量")
                        .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Theme.faint)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(status.kicker)
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .frame(height: 21)
                        .background(Capsule().fill(accent.opacity(0.12)))
                        .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 1))

                    Text(status.headline)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)

                    Text(status.message)
                        .font(.system(size: 9.3))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 170, alignment: .trailing)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 4) {
                Text("BATTERY LEVEL")
                    .font(.system(size: 6.6, weight: .medium, design: .monospaced))
                    .tracking(0.85)
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text("\(device.battery.map(String.init) ?? "--") / 100")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.bottom, 6)

            batteryBar(fraction: fraction, color: accent, charging: device.charging == true)

            HStack(spacing: 6) {
                Text(device.source)
                    .font(.system(size: 7.4, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Theme.faint)
                Circle().fill(Theme.faint.opacity(0.7)).frame(width: 2, height: 2)
                Text(device.connectionLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                if device.charging == true {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 7))
                        Text("充电中").font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(Theme.teal)
                } else if device.isStale {
                    Text("等待响应")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.amber)
                } else {
                    Text(intervalLabel(model.settings.refreshInterval) + "刷新")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.top, 9)
        }
        .padding(16)
        .frame(height: 200, alignment: .top)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.095, green: 0.115, blue: 0.088),
                                Color(red: 0.028, green: 0.036, blue: 0.029),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RadialGradient(
                    colors: [accent.opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 2,
                    endRadius: 250
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }

    private func batteryBar(fraction: CGFloat, color: Color, charging: Bool) -> some View {
        HStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.055))

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.68), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(7, geometry.size.width * min(1, max(0, fraction))))
                        .shadow(color: color.opacity(0.35), radius: 7, y: 1)

                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Color.black.opacity(0.18))
                                .frame(width: 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .offset(x: 7)
                    }
                }
                .animation(.easeOut(duration: 0.5), value: fraction)
            }
            .frame(height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )

            RoundedRectangle(cornerRadius: 1.2)
                .fill(color.opacity(0.55))
                .frame(width: 3, height: 6)
        }
    }

    private func metrics(_ device: MouseDevice) -> some View {
        HStack(spacing: 0) {
            metric(
                icon: "wifi",
                title: "连接方式",
                value: device.connectionLabel,
                tint: accent
            )
            metricDivider
            metric(
                icon: device.charging == true ? "bolt.fill" : "powerplug.fill",
                title: "电源状态",
                value: powerState(device),
                tint: device.charging == true ? Theme.teal : Theme.muted
            )
            metricDivider
            metric(
                icon: "cpu",
                title: "数据来源",
                value: device.source,
                tint: Theme.muted
            )
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func metric(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(title)
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
            }
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1, height: 30)
    }

    private func refreshRow(_ device: MouseDevice) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isScanning ? Theme.amber : accent)
                .frame(width: 4, height: 4)
            Text(updatedText(device))
                .font(.system(size: 8.3, design: .monospaced))
                .foregroundStyle(Theme.faint)
            Spacer()
            Button(action: actions.refresh) {
                HStack(spacing: 5) {
                    if model.isScanning {
                        ProgressView().controlSize(.mini).tint(Theme.muted)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    Text(model.isScanning ? "读取中" : "重新读取")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
        }
        .padding(.top, 1)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已发现的设备")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("\(model.devices.count)")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
            }
            ForEach(model.devices) { device in
                Button {
                    actions.selectDevice(device.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "computermouse")
                            .font(.system(size: 12))
                            .foregroundStyle(device.id == model.activeDevice?.id ? accent : Theme.muted)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.text.opacity(0.84))
                                .lineLimit(1)
                            Text(device.isStale ? "等待响应 · \(device.connectionLabel)" : "\(device.connectionLabel) · \(device.source)")
                                .font(.system(size: 8.2))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        batteryPill(device)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 43)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(device.id == model.activeDevice?.id ? accent.opacity(0.10) : Color.white.opacity(0.022))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(device.id == model.activeDevice?.id ? accent.opacity(0.18) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func batteryPill(_ device: MouseDevice) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 30, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(deviceColor(device))
                        .frame(width: max(3, 30 * CGFloat(device.battery ?? 0) / 100), height: 3)
                }
            Text(device.batteryText)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .frame(width: 27, alignment: .trailing)
        }
    }

    private var supportLine: some View {
        HStack(spacing: 5) {
            Text("支持")
                .font(.system(size: 7.2, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.faint)
            supportChip("ATK / VXE", color: Theme.volt)
            supportChip("Razer · 实验", color: Theme.amber)
            supportChip("蓝牙", color: Theme.teal)
            Spacer(minLength: 2)
            Text("Win/Linux 规划中")
                .font(.system(size: 7.2, design: .monospaced))
                .foregroundStyle(Theme.faint.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .frame(height: 33)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 1))
        .padding(.top, 1)
    }

    private func supportChip(_ text: String, color: Color) -> some View {
        HStack(spacing: 3.5) {
            Circle().fill(color).frame(width: 3.5, height: 3.5)
            Text(text)
                .font(.system(size: 7.4))
                .foregroundStyle(Theme.text.opacity(0.76))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.8))
    }

    private var issueBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.issues.first?.message ?? "读取提示")
                    .font(.system(size: 9.2, weight: .medium))
                    .foregroundStyle(Theme.amber.opacity(0.95))
                if let detail = model.issues.first?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8.2))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber.opacity(0.16), lineWidth: 1))
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: 86, height: 52)
                BattBarMark(color: Theme.muted)
                    .scaleEffect(2.6)
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
                    .offset(y: 44)
            }
            .padding(.bottom, 24)
            Text("正在读取设备电量")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("ATK / Razer 接收器与系统蓝牙设备会自动识别")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 430)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .frame(width: 156, height: 92)
                BattBarMark(color: Theme.muted.opacity(0.85))
                    .scaleEffect(3.8)
            }
            .padding(.bottom, 8)
            Text("没有发现设备")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("请确认接收器已插好，或在系统设置中连接蓝牙鼠标。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button(action: actions.refresh) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新扫描")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.06, green: 0.09, blue: 0.03))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(accent))
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

    // MARK: - Settings

    private var settings: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SETTINGS")
                        .font(.system(size: 7.2, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Theme.faint)
                    Text("偏好设置")
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
                                .foregroundStyle(Theme.text.opacity(0.84))
                            Spacer()
                            Text("每 \(intervalLabel(model.settings.refreshInterval))自动读取")
                                .font(.system(size: 8.2))
                                .foregroundStyle(Theme.faint)
                        }
                        HStack(spacing: 2) {
                            ForEach([30, 60, 120, 300], id: \.self) { interval in
                                Button {
                                    actions.setRefreshInterval(interval)
                                } label: {
                                    Text(intervalLabel(interval))
                                        .font(.system(size: 9.3))
                                        .foregroundStyle(model.settings.refreshInterval == interval ? Theme.text : Theme.muted)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 26)
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
                    VStack(spacing: 2) {
                        settingsAction("ladybug", title: "复制诊断信息", subtitle: "用于排查读取问题", action: actions.copyDiagnostics)
                        Divider().overlay(Theme.line).padding(.leading, 34)
                        settingsAction("bell.badge", title: "发送测试通知", subtitle: "验证系统通知权限", action: actions.testNotification)
                    }
                }

                if let message = model.settingsMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text(message)
                            .font(.system(size: 8.8))
                    }
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.opacity(0.09))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(accent.opacity(0.16), lineWidth: 1)
                            )
                        BattBarMark(color: accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("BattBar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2")")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.text.opacity(0.88))
                        Text("电量栏 · 原生版 · ATK / Razer / 蓝牙")
                            .font(.system(size: 8.2))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("LOCAL")
                        .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.11)))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))

                Button(action: actions.quit) {
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .font(.system(size: 9))
                        Text("退出电量栏")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(Color(red: 0.88, green: 0.57, blue: 0.52))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.red.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.red.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Text("电量数据仅在本机读取，不会上传到任何服务器。")
                    .font(.system(size: 7.8))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 1)
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
                    .foregroundStyle(Theme.text.opacity(0.84))
                Text(subtitle)
                    .font(.system(size: 8.2))
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
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.3))
                        .foregroundStyle(Theme.text.opacity(0.84))
                    Text(subtitle)
                        .font(.system(size: 8.2))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isScanning ? Theme.amber : accent)
                .frame(width: 4, height: 4)
            Text(model.isScanning ? "正在读取电量…" : "\(model.devices.count) 台设备 · \(model.autoRefreshText)")
                .font(.system(size: 8.3))
                .foregroundStyle(Theme.faint)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 8.5))
                Text("仅本机读取")
                    .font(.system(size: 8.3))
            }
            .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18)
        .frame(height: 39)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line.opacity(0.75)).frame(height: 1)
        }
    }

    // MARK: - Data helpers

    private var accent: Color {
        color(for: model.activeDevice)
    }

    private func color(for device: MouseDevice?) -> Color {
        guard let device, let battery = device.battery else { return Theme.volt }
        if device.isStale { return Theme.amber }
        if device.charging == true { return Theme.teal }
        if battery <= 20 { return Theme.coral }
        if battery <= 40 { return Theme.amber }
        return Theme.volt
    }

    private func deviceColor(_ device: MouseDevice) -> Color {
        color(for: device)
    }

    private func powerState(_ device: MouseDevice) -> String {
        if device.isStale { return "等待响应" }
        if device.charging == true { return "充电中" }
        if device.charging == false { return "使用中" }
        return "未知"
    }

    private func status(for device: MouseDevice) -> (kicker: String, headline: String, message: String) {
        guard let battery = device.battery else {
            return ("等待数据", "暂时没有读数", "设备已连接，正在等待有效的电量数据。")
        }
        if device.isStale {
            return ("上次读数", "等待设备唤醒", "接收器暂时没有响应，唤醒设备后会自动更新。")
        }
        if device.charging == true {
            if battery >= 100 {
                return ("已充满", "电量满格", "电池已经充满，可以拔掉线继续使用。")
            }
            return ("充电中", "电量回升中", "正在为设备补能，可以继续使用。")
        }
        if battery <= 10 {
            return ("电量告急", "请立即充电", "电量即将耗尽，建议立即连接充电线。")
        }
        if battery <= 20 {
            return ("低电量", "建议尽快充电", "电量偏低，避免在关键使用中突然断开。")
        }
        if battery <= 40 {
            return ("电量偏低", "准备补电", "已接近低电量，方便时请为设备充电。")
        }
        if battery <= 70 {
            return ("状态良好", "电量健康", "当前电量足够日常使用。")
        }
        return ("电量充足", "随时可用", "电量充足，可以放心使用。")
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

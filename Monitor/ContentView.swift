import AppKit
import SwiftUI

struct ContentView: View {
    var viewModel: SystemMonitorViewModel

    @StateObject private var dashboard = DashboardRuntimeViewModel()
    @State private var showSettings = false
    @State private var liveSystemColorScheme = Self.currentSystemColorScheme()
    @State private var launchAtLoginEnabled = false

    @AppStorage(DashboardAppearanceStorage.appearanceKey) private var appearanceModeRaw = DashboardAppearanceMode.system.rawValue
    @AppStorage(DashboardAppearanceStorage.themeKey) private var themeStyleRaw = DashboardThemeStyle.amber.rawValue
    @AppStorage(DashboardAppearanceStorage.accentKey) private var accentStyleRaw = DashboardAccentStyle.mint.rawValue
    @AppStorage(MonitorPreferencesService.powerRefreshIntervalKey) private var powerRefreshInterval = MonitorPreferencesService.defaultPowerRefreshInterval
    @AppStorage(MonitorPreferencesService.bluetoothRefreshIntervalKey) private var bluetoothRefreshInterval = MonitorPreferencesService.defaultBluetoothRefreshInterval

    private var appearanceMode: DashboardAppearanceMode {
        DashboardAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var themeStyle: DashboardThemeStyle {
        DashboardThemeStyle(rawValue: themeStyleRaw) ?? .amber
    }

    private var accentStyle: DashboardAccentStyle {
        DashboardAccentStyle(rawValue: accentStyleRaw) ?? .mint
    }

    private var resolvedColorScheme: ColorScheme {
        appearanceMode.resolvedColorScheme(system: liveSystemColorScheme)
    }

    private var palette: DashboardPalette {
        DashboardPalette.resolve(colorScheme: resolvedColorScheme, theme: themeStyle, accent: accentStyle)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LiquidGlassBackground()
                .environment(\.dashboardPalette, palette)
                .ignoresSafeArea()

            VStack(spacing: MonitorPanelLayout.cardSpacing) {
                headerSection
                metricGrid
                batterySection
                processSection
            }
            .padding(MonitorPanelLayout.contentPadding)
            .zIndex(0)

            if showSettings {
                settingsDimmer
                    .zIndex(2)
                settingsPopup
                    .padding(.top, MonitorPanelLayout.contentPadding + 44)
                    .padding(.leading, MonitorPanelLayout.contentPadding)
                    .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: showSettings)
        .environment(\.dashboardPalette, palette)
        .preferredColorScheme(appearanceMode.preferredColorScheme)
        .frame(width: MonitorPanelLayout.designWidth, height: MonitorPanelLayout.designHeight)
        .clipShape(MonitorTheme.panelShape)
        .overlay(
            MonitorTheme.panelShape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(palette.isDark ? 0.20 : 0.50), palette.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .onAppear {
            liveSystemColorScheme = Self.currentSystemColorScheme()
            launchAtLoginEnabled = LaunchAtLoginService.isEnabled
            applyDashboardAppearance()
            dashboard.start(mode: .background, forceRefresh: true)
        }
        .onChange(of: appearanceModeRaw) {
            applyDashboardAppearance()
            liveSystemColorScheme = Self.currentSystemColorScheme()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            liveSystemColorScheme = Self.currentSystemColorScheme()
        }
        .onReceive(NotificationCenter.default.publisher(for: MonitorPanelLifecycleNotification.didOpen)) { _ in
            liveSystemColorScheme = Self.currentSystemColorScheme()
            launchAtLoginEnabled = LaunchAtLoginService.isEnabled
            dashboard.setRefreshMode(.foreground, forceRefresh: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: MonitorPanelLifecycleNotification.didClose)) { _ in
            dashboard.setRefreshMode(.background, forceRefresh: false)
        }
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    @MainActor
    private func applyDashboardAppearance() {
        appearanceMode.applyToApplication()
    }
}

// MARK: - Layout Sections

private extension ContentView {
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(statusColor)
                    .symbolRenderingMode(.hierarchical)

                Text("\(dashboard.healthScore)")
                    .font(.system(size: 35, weight: .heavy, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .monospacedDigit()

                Text(headerIssueText)
                    .font(MonitorFont.heiti(size: 14))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("设置")

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("退出")
                }
            }

            HStack(spacing: 6) {
                HeaderChip(text: chipName)
                HeaderChip(text: memoryChip)
                HeaderChip(text: macOSChip)
                HeaderChip(text: "已运行 \(dashboard.uptimeDisplay)")
            }
        }
        .frame(height: MonitorPanelLayout.headerHeight, alignment: .topLeading)
    }

    var metricGrid: some View {
        VStack(spacing: MonitorPanelLayout.cardSpacing) {
            HStack(spacing: MonitorPanelLayout.cardSpacing) {
                MetricCard(
                    title: "CPU",
                    value: dashboard.cpuLoadDisplay,
                    unit: "%",
                    badgeText: dashboard.cpuTemperatureDisplay == "—" ? nil : "\(dashboard.cpuTemperatureDisplay)°C",
                    subtitle: cpuSubtitle,
                    symbol: "cpu",
                    color: palette.accent,
                    progress: dashboard.cpuUsagePercent / 100,
                    samples: dashboard.history.map(\.cpuUsage),
                    showsChart: true,
                    showsProgress: false
                )

                MetricCard(
                    title: "GPU",
                    value: dashboard.gpuUsageDisplay,
                    unit: dashboard.gpuUsageDisplay == "—" ? "" : "%",
                    badgeText: dashboard.gpuTemperatureDisplay == "—" ? nil : "\(dashboard.gpuTemperatureDisplay)°C",
                    subtitle: gpuSubtitle,
                    symbol: "display",
                    color: palette.orange,
                    progress: (dashboard.gpuUsagePercent ?? 0) / 100,
                    samples: dashboard.history.map { $0.gpuUsage ?? 0 },
                    showsChart: true,
                    showsProgress: false
                )
            }

            HStack(spacing: MonitorPanelLayout.cardSpacing) {
                MetricCard(
                    title: "内存",
                    value: String(format: "%.0f", dashboard.memoryUsageFraction * 100),
                    unit: "%",
                    badgeText: memoryPressureBadge,
                    subtitle: "交换空间 \(dashboard.memorySwapDisplay)",
                    symbol: "memorychip",
                    color: palette.sand,
                    progress: dashboard.memoryUsageFraction,
                    samples: dashboard.history.map(\.memoryUsage),
                    showsChart: true,
                    showsProgress: false
                )

                MetricCard(
                    title: "磁盘",
                    value: String(format: "%.0f", dashboard.storageUsageFraction * 100),
                    unit: "%",
                    badgeText: dashboard.storageTotalDisplay == "—" ? nil : dashboard.storageTotalDisplay,
                    subtitle: "可用 \(dashboard.storageAvailableDisplay)",
                    symbol: "internaldrive",
                    color: palette.blue,
                    progress: dashboard.storageUsageFraction,
                    samples: dashboard.history.map(\.storageUsage),
                    showsChart: false,
                    showsProgress: true
                )
            }

            HStack(spacing: MonitorPanelLayout.cardSpacing) {
                MetricCard(
                    title: "网络",
                    value: compactNetworkDisplay,
                    unit: "",
                    badgeText: dashboard.networkKindDisplay,
                    subtitle: "↑ \(dashboard.uploadSpeedDisplay) · ↓ \(dashboard.downloadSpeedDisplay)",
                    symbol: "network",
                    color: palette.cyan,
                    progress: networkProgress,
                    samples: dashboard.history.map(\.downloadKBs),
                    secondarySamples: dashboard.history.map(\.uploadKBs),
                    showsChart: true,
                    showsProgress: false
                )

                MetricCard(
                    title: "温度",
                    value: dashboard.cpuTemperatureDisplay,
                    unit: dashboard.cpuTemperatureDisplay == "—" ? "" : "°C",
                    badgeText: temperatureBadgeText,
                    subtitle: dashboard.gpuTemperatureDisplay == "—" ? "GPU —" : "GPU \(dashboard.gpuTemperatureDisplay)°C",
                    symbol: "thermometer.medium",
                    color: temperatureColor,
                    progress: temperatureProgress,
                    samples: dashboard.history.map { $0.cpuTemperature ?? 0 },
                    showsChart: false,
                    showsProgress: true
                )
            }
        }
    }

    var batterySection: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: dashboard.batteryCharging ? "powerplug" : "battery.75")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Text("电源")
                        .font(MonitorFont.heiti(size: 12))
                        .foregroundStyle(palette.accent)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        BatteryPercentPill(percent: dashboard.batteryPercentage, charging: dashboard.batteryCharging)
                    }
                }

                PowerFlowView(
                    flow: dashboard.batteryPowerFlow,
                    stateText: dashboard.batteryPowerStateDisplay,
                    batteryDisplay: dashboard.batteryDisplay
                )

                if !dashboard.accessoryBatteries.isEmpty {
                    AccessoryBatteryBars(accessories: dashboard.accessoryBatteries)
                }
            }
        }
        .frame(height: MonitorPanelLayout.batteryCardHeight + (dashboard.accessoryBatteries.isEmpty ? 0 : MonitorPanelLayout.batteryAccessoryBarHeight))
    }

    var processSection: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                        Text("高占用进程")
                            .font(MonitorFont.heiti(size: 12))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                    Text("CPU")
                        .font(MonitorFont.helvetica(size: 10))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 54, alignment: .trailing)
                    Text("内存")
                        .font(MonitorFont.heiti(size: 10))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 54, alignment: .trailing)
                    Color.clear
                        .frame(width: 22, height: 1)
                }

                if dashboard.topProcesses.isEmpty {
                    Text("暂无可显示进程")
                        .font(MonitorFont.heiti(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(dashboard.topProcesses.prefix(5))) { process in
                            ProcessRow(process: process) {
                                confirmTerminate(process)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: processCardHeight)
    }

    var settingsDimmer: some View {
        Color.black.opacity(palette.isDark ? 0.10 : 0.04)
            .contentShape(Rectangle())
            .onTapGesture { showSettings = false }
    }

    var settingsPopup: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("外观与配色")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Button {
                        showSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(palette.chipBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                SettingsOptionRow(title: "模式") {
                    ForEach(DashboardAppearanceMode.allCases) { mode in
                        CapsuleOption(title: mode.title, selected: appearanceMode == mode) {
                            appearanceModeRaw = mode.rawValue
                        }
                    }
                }

                SettingsOptionRow(title: "主题") {
                    ForEach(DashboardThemeStyle.allCases) { theme in
                        ColorDotOption(title: theme.title, color: theme.previewColor, selected: themeStyle == theme) {
                            themeStyleRaw = theme.rawValue
                        }
                    }
                }

                SettingsOptionRow(title: "强调") {
                    ForEach(DashboardAccentStyle.allCases) { accent in
                        ColorDotOption(title: accent.title, color: accent.color, selected: accentStyle == accent) {
                            accentStyleRaw = accent.rawValue
                        }
                    }
                }

                SettingsToggleRow(title: "开机启动", symbol: "power", isOn: launchAtLoginEnabled) {
                    let targetValue = !launchAtLoginEnabled
                    if LaunchAtLoginService.setEnabled(targetValue) {
                        launchAtLoginEnabled = LaunchAtLoginService.isEnabled
                    }
                }

                SettingsIntervalRow(
                    title: "电源刷新",
                    symbol: "bolt.horizontal",
                    value: Int(powerRefreshInterval),
                    range: 3...60,
                    step: 1
                ) { value in
                    MonitorPreferencesService.savePowerRefreshInterval(TimeInterval(value))
                    powerRefreshInterval = MonitorPreferencesService.powerRefreshInterval()
                }

                SettingsIntervalRow(
                    title: "蓝牙刷新",
                    symbol: "dot.radiowaves.left.and.right",
                    value: Int(bluetoothRefreshInterval),
                    range: 15...180,
                    step: 15
                ) { value in
                    MonitorPreferencesService.saveBluetoothRefreshInterval(TimeInterval(value))
                    bluetoothRefreshInterval = MonitorPreferencesService.bluetoothRefreshInterval()
                }

                SettingsInfoRow(title: "版本", value: appVersionDisplay)
            }
        }
        .frame(width: MonitorPanelLayout.designWidth - MonitorPanelLayout.contentPadding * 2)
        .monitorMenuListShadow(colorScheme: palette.isDark ? .dark : .light)
    }
}

// MARK: - Computed helpers

private extension ContentView {
    var headerSymbol: String {
        dashboard.healthScore >= 80 ? "sun.max.fill" : dashboard.healthScore >= 55 ? "speedometer" : "thermometer.high"
    }

    var healthStatusText: String {
        if let maxTemperature, maxTemperature >= 85 { return "CPU 温度偏高" }
        if dashboard.healthScore >= 80 { return "运行状态良好" }
        if dashboard.healthScore >= 55 { return "负载偏高" }
        return "需要关注"
    }

    var headerIssueText: String {
        if dashboard.storageUsageFraction >= 0.82, dashboard.storageAvailableDisplay != "—" {
            return "磁盘空间不足 · \(dashboard.storageAvailableDisplay) 可用"
        }
        if let maxTemperature, maxTemperature >= 70 {
            return "\(temperatureBadgeText ?? "温度偏高") · \(maxTemperatureDisplay)°C"
        }
        return healthStatusText
    }

    var statusColor: Color {
        dashboard.healthScore >= 80 ? palette.accent : dashboard.healthScore >= 55 ? palette.orange : palette.red
    }

    var processCardHeight: CGFloat {
        let count = dashboard.topProcesses.isEmpty ? 0 : min(dashboard.topProcesses.count, 5)
        if count == 0 { return 96 }
        return 42 + CGFloat(count) * 20 + CGFloat(max(count - 1, 0)) * 4
    }

    var chipName: String {
        let parts = dashboard.headerSummary.components(separatedBy: " · ")
        guard parts.count >= 2 else { return "Mac" }
        return parts[1]
            .replacingOccurrences(of: "Apple ", with: "")
            .replacingOccurrences(of: "chip", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var memoryChip: String {
        dashboard.memoryTotalDisplay == "—" ? "内存 —" : dashboard.memoryTotalDisplay
    }

    var macOSChip: String {
        let parts = dashboard.headerSummary.components(separatedBy: " · ")
        return parts.first(where: { $0.hasPrefix("macOS") }) ?? "macOS"
    }

    var cpuSubtitle: String {
        let load = min(max(dashboard.cpuUsagePercent / 10, 0), 10)
        let state: String
        if dashboard.cpuUsagePercent < 70 {
            state = "正常"
        } else if dashboard.cpuUsagePercent < 90 {
            state = "偏高"
        } else {
            state = "高负载"
        }
        return String(format: "负载 %.1f/10 · %@", load, state)
    }

    var gpuSubtitle: String {
        let busy = dashboard.gpuUsageDisplay == "—" ? "繁忙度 —" : "繁忙度 \(dashboard.gpuUsageDisplay)%"
        let cores = dashboard.gpuCoreCount.map { "\($0) 核" } ?? "核心数 —"
        return "\(busy) · \(cores)"
    }

    var memoryPressureBadge: String? {
        let value = Int((dashboard.memoryUsageFraction * 100).rounded())
        return "压力 \(value)%"
    }

    var compactNetworkDisplay: String {
        if dashboard.downloadSpeedDisplay == "0 B/s", dashboard.uploadSpeedDisplay == "0 B/s" { return "<1 KB/s" }
        let total = (dashboard.history.last?.downloadKBs ?? 0) + (dashboard.history.last?.uploadKBs ?? 0)
        guard total >= 1 else { return "<1 KB/s" }
        return ByteFormatting.formatBytesPerSecond(total * 1024)
    }

    var appVersionDisplay: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var maxTemperature: Double? {
        let values = [dashboard.cpuTemperatureCelsius, dashboard.gpuTemperatureCelsius].compactMap { $0 }
        return values.max()
    }

    var maxTemperatureDisplay: String {
        guard let maxTemperature else { return "—" }
        return String(format: "%.0f", maxTemperature)
    }

    var temperatureBadgeText: String? {
        guard let cpuTemperature = dashboard.cpuTemperatureCelsius else { return nil }
        if cpuTemperature >= 85 { return "过热" }
        if cpuTemperature >= 70 { return "偏高" }
        return "正常"
    }

    var temperatureProgress: Double {
        min(max((dashboard.cpuTemperatureCelsius ?? 0) / 100, 0), 1)
    }

    var temperatureColor: Color {
        guard let cpuTemperature = dashboard.cpuTemperatureCelsius else { return palette.secondaryText }
        if cpuTemperature >= 85 { return palette.red }
        if cpuTemperature >= 70 { return palette.orange }
        return palette.accent
    }

    var networkProgress: Double {
        let latest = dashboard.history.last?.downloadKBs ?? 0
        return min(max(latest / 4096, 0), 1)
    }

    var topPowerConsumerText: String {
        guard let process = dashboard.topProcesses.first else { return "—" }
        return "\(process.name) · \(process.cpuDisplay)"
    }

    func confirmTerminate(_ process: DashboardProcess) {
        let alert = NSAlert()
        alert.messageText = "结束进程？"
        alert.informativeText = "将向 \(process.name) 发送 SIGTERM。未保存的数据可能丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "结束")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            dashboard.terminate(process)
        }
    }
}

// MARK: - Liquid Glass Components

private struct LiquidGlassBackground: View {
    @Environment(\.dashboardPalette) private var palette

    var body: some View {
        ZStack {
            palette.panelBackground
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(palette.isDark ? 0.34 : 0.08)
            if !palette.isDark {
                Rectangle()
                    .fill(Color.white.opacity(0.54))
            }
            LinearGradient(
                colors: [Color.white.opacity(palette.isDark ? 0.08 : 0.42), Color.clear, Color.black.opacity(palette.isDark ? 0.22 : 0.01)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [palette.accent.opacity(palette.isDark ? 0.20 : 0.16), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [palette.orange.opacity(palette.isDark ? 0.12 : 0.08), Color.clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 360
            )
        }
    }
}

private struct LiquidGlassCard<Content: View>: View {
    @Environment(\.dashboardPalette) private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if palette.isDark {
                    MonitorTheme.cardShape.fill(.ultraThinMaterial)
                } else {
                    MonitorTheme.cardShape.fill(Color.white.opacity(0.58))
                }
            }
            .background(palette.cardBackground, in: MonitorTheme.cardShape)
            .overlay(
                MonitorTheme.cardShape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(palette.isDark ? 0.15 : 0.78), palette.border.opacity(palette.isDark ? 0.45 : 0.34)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
            )
            .overlay(alignment: .topLeading) {
                MonitorTheme.cardShape
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(palette.isDark ? 0.08 : 0.42), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(MonitorTheme.cardShape)
            .monitorCardShadow(colorScheme: palette.isDark ? .dark : .light)
    }
}

private enum MonitorFont {
    static func helvetica(size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Helvetica-Bold" : "Helvetica", size: size)
    }

    static func heiti(size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Heiti SC" : "STHeitiSC-Light", size: size)
    }

    static func label(_ text: String, size: CGFloat, bold: Bool = false) -> Font {
        let containsChinese = text.unicodeScalars.contains { scalar in
            scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
        }
        return containsChinese ? heiti(size: size, bold: bold) : helvetica(size: size, bold: bold)
    }
}

private struct MetricCard: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let value: String
    let unit: String
    let badgeText: String?
    let subtitle: String
    let symbol: String
    let color: Color
    let progress: Double
    let samples: [Double]
    var secondarySamples: [Double]? = nil
    let showsChart: Bool
    let showsProgress: Bool

    var body: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                    Text(title)
                        .font(MonitorFont.label(title, size: 11))
                        .tracking(title.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ? 0 : 1.5)
                        .foregroundStyle(color)
                    Spacer(minLength: 0)
                    if let badgeText {
                        Text(badgeText)
                            .font(MonitorFont.helvetica(size: 10, bold: true))
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(MonitorFont.helvetica(size: value.count > 5 ? 19 : 26, bold: true))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.60)
                        .monospacedDigit()
                    Text(unit)
                        .font(MonitorFont.helvetica(size: 11, bold: true))
                        .foregroundStyle(palette.secondaryText)
                }

                if showsChart {
                    Group {
                        if let secondarySamples {
                            MiniNetworkChart(downloadSamples: samples, uploadSamples: secondarySamples, uploadColor: palette.accent, downloadColor: palette.blue)
                        } else {
                            MiniLineChart(samples: samples, color: color)
                        }
                    }
                    .frame(height: 29)
                }

                if showsProgress {
                    Spacer(minLength: 0)
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(DashboardProgressStyle(color: color))
                        .padding(.top, 1)
                } else {
                    Spacer(minLength: 0)
                }

                subtitleFooter
            }
        }
        .frame(width: (MonitorPanelLayout.contentAreaWidth - MonitorPanelLayout.cardSpacing) / 2, height: MonitorPanelLayout.metricCardHeight)
    }

    private var subtitleFooter: some View {
        let parts = subtitle.components(separatedBy: " · ")
        return HStack(spacing: 4) {
            Text(parts.first ?? subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if parts.count > 1 {
                Text(parts.dropFirst().joined(separator: " · "))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(MonitorFont.helvetica(size: 10, bold: true))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
}

private struct MiniNetworkChart: View {
    @Environment(\.dashboardPalette) private var palette
    let downloadSamples: [Double]
    let uploadSamples: [Double]
    let uploadColor: Color
    let downloadColor: Color

    var body: some View {
        GeometryReader { proxy in
            let upload = normalized(uploadSamples)
            let download = normalized(downloadSamples)
            let midY = proxy.size.height * 0.50
            ZStack {
                Rectangle()
                    .fill(palette.chipBackground.opacity(0.55))
                    .frame(height: 1)
                    .position(x: proxy.size.width / 2, y: midY)

                networkPath(values: upload, size: proxy.size, aboveMidline: true)
                    .stroke(uploadColor.opacity(0.96), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

                networkPath(values: download, size: proxy.size, aboveMidline: false)
                    .stroke(downloadColor.opacity(0.96), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
        }
        .background(
            LinearGradient(
                colors: [downloadColor.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func networkPath(values: [Double], size: CGSize, aboveMidline: Bool) -> Path {
        let midY = size.height * 0.50
        let amplitude = size.height * 0.38
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        var path = Path()
        for index in values.indices {
            let x = CGFloat(index) * step
            let offset = CGFloat(values[index]) * amplitude
            let y = aboveMidline ? midY - offset : midY + offset
            if index == values.startIndex { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func normalized(_ samples: [Double]) -> [Double] {
        let recent = Array(samples.suffix(24))
        guard let maxValue = recent.max(), maxValue > 0 else {
            return [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        }
        return recent.map { min(max($0 / maxValue, 0.0), 1.0) }
    }
}

private struct MiniLineChart: View {
    @Environment(\.dashboardPalette) private var palette
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let values = normalizedSamples
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [color.opacity(0.15), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Path { path in
                    guard !values.isEmpty else { return }
                    let step = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0
                    for index in values.indices {
                        let x = CGFloat(index) * step
                        let y = proxy.size.height * (1 - CGFloat(values[index]))
                        if index == values.startIndex { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color.opacity(0.96), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .background(
            LinearGradient(
                colors: [color.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var normalizedSamples: [Double] {
        let recent = Array(samples.suffix(24))
        guard let maxValue = recent.max(), maxValue > 0 else { return [0.10, 0.11, 0.10, 0.12, 0.11, 0.10] }
        return recent.map { min(max($0 / maxValue, 0.06), 1.0) }
    }
}

private struct ProcessRow: View {
    @Environment(\.dashboardPalette) private var palette
    let process: DashboardProcess
    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(MonitorFont.helvetica(size: 11, bold: true))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(process.cpuDisplay)
                .font(MonitorFont.helvetica(size: 10.5, bold: true))
                .foregroundStyle(process.cpuPercent >= 80 ? palette.red : palette.secondaryText)
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            Text(process.memoryDisplay)
                .font(MonitorFont.helvetica(size: 10.5, bold: true))
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            Button(action: onTerminate) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(palette.tertiaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 20)
    }
}

private struct SettingsButton: View {
    @Environment(\.dashboardPalette) private var palette
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOpen ? "gearshape.fill" : "gearshape")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(isOpen ? palette.onAccent : palette.primaryText)
                .frame(width: 30, height: 30)
                .background(isOpen ? palette.accent : palette.chipBackground)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderChip: View {
    @Environment(\.dashboardPalette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.chipBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct TemperatureBadge: View {
    @Environment(\.dashboardPalette) private var palette
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct BatteryPercentPill: View {
    @Environment(\.dashboardPalette) private var palette
    let percent: Int?
    let charging: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: charging ? "bolt.batteryblock.fill" : "battery.75")
                .font(.system(size: 10, weight: .bold))
            Text(percent.map { "\($0)%" } ?? "—")
                .font(MonitorFont.helvetica(size: 10, bold: true))
                .monospacedDigit()
        }
        .foregroundStyle(charging ? palette.accent : palette.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(palette.chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AccessoryBatteryPill: View {
    @Environment(\.dashboardPalette) private var palette
    let accessory: AccessoryBatterySnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: accessory.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text("\(accessory.percentage)%")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(palette.chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("\(accessory.name) \(accessory.percentage)%")
    }
}

private struct AccessoryBatteryBars: View {
    @Environment(\.dashboardPalette) private var palette
    let accessories: [AccessoryBatterySnapshot]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(accessories) { accessory in
                HStack(spacing: 6) {
                    Image(systemName: accessory.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                    Text(accessory.name)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(palette.chipBackground)
                            Capsule(style: .continuous)
                                .fill(palette.accent.opacity(0.85))
                                .frame(width: proxy.size.width * min(max(Double(accessory.percentage) / 100, 0), 1))
                        }
                    }
                    .frame(height: 5)
                    Text("\(accessory.percentage)%")
                        .font(MonitorFont.helvetica(size: 9, bold: true))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(palette.chipBackground.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("\(accessory.name) \(accessory.percentage)%")
            }
        }
        .frame(height: MonitorPanelLayout.batteryAccessoryBarHeight)
    }
}

private struct PowerFlowView: View {
    @Environment(\.dashboardPalette) private var palette
    let flow: PowerFlowSnapshot
    let stateText: String
    let batteryDisplay: String

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let endpointWidth: CGFloat = 48
            let gap: CGFloat = 7
            let bandX = endpointWidth + gap
            let bandWidth = max(size.width - endpointWidth * 2 - gap * 2, 24)

            ZStack(alignment: .topLeading) {
                ForEach(Array(sourceItems.enumerated()), id: \.element.id) { index, item in
                    endpoint(item: item, height: nodeHeight(for: sourceItems.count))
                        .frame(width: endpointWidth, height: nodeHeight(for: sourceItems.count))
                        .offset(x: 0, y: nodeY(index: index, count: sourceItems.count))
                }

                SankeyPowerBands(
                    routes: flowRoutes,
                    sourceCount: sourceItems.count,
                    destinationCount: destinationItems.count
                )
                .frame(width: bandWidth, height: size.height)
                .offset(x: bandX, y: 0)

                ForEach(flowRoutes) { route in
                    Text(route.powerText)
                        .font(MonitorFont.helvetica(size: flowRoutes.count == 1 ? 13 : 10, bold: true))
                        .foregroundStyle(palette.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.chipBackground.opacity(palette.isDark ? 0.18 : 0.34))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .frame(width: bandWidth * 0.62)
                        .position(
                            x: bandX + bandWidth / 2,
                            y: routeMidY(route)
                        )
                }

                ForEach(Array(destinationItems.enumerated()), id: \.element.id) { index, item in
                    endpoint(item: item, height: destinationNodeHeight(index: index))
                        .frame(width: endpointWidth, height: destinationNodeHeight(index: index))
                        .offset(
                            x: endpointWidth + gap + bandWidth + gap,
                            y: destinationNodeY(index: index)
                        )
                }
            }
        }
        .frame(height: 72)
    }

    private var sourceItems: [PowerEndpointItem] {
        if flow.isPluggedIn {
            return [PowerEndpointItem(symbol: "powerplug.fill", label: flow.adapterWatts.map(formatPower), tint: palette.secondaryText)]
        }
        return [PowerEndpointItem(symbol: "battery.75", label: batteryLabel, tint: palette.sand)]
    }

    private var destinationItems: [PowerEndpointItem] {
        if flow.isPluggedIn, flow.isActivelyCharging {
            return [
                PowerEndpointItem(symbol: "laptopcomputer", label: nil, tint: palette.secondaryText),
                PowerEndpointItem(symbol: "battery.75", label: batteryLabel, tint: palette.accent)
            ]
        }
        return [PowerEndpointItem(symbol: "laptopcomputer", label: nil, tint: palette.secondaryText)]
    }

    private var flowRoutes: [PowerFlowRoute] {
        if flow.isPluggedIn, flow.isActivelyCharging {
            return [
                PowerFlowRoute(sourceIndex: 0, destinationIndex: 0, watts: flow.systemWatts, powerText: flow.systemWatts.map(formatPower) ?? "直接供电"),
                PowerFlowRoute(sourceIndex: 0, destinationIndex: 1, watts: flow.batteryWatts, powerText: flow.batteryWatts.map(formatPower) ?? "给电池供电")
            ]
        }
        return [PowerFlowRoute(sourceIndex: 0, destinationIndex: 0, watts: primaryWatts, powerText: primaryPowerText)]
    }

    private var primaryWatts: Double? {
        if flow.isDischarging { return flow.batteryWatts }
        if flow.isPluggedIn { return flow.systemWatts ?? flow.adapterWatts }
        return nil
    }

    private var primaryPowerText: String {
        if flow.isDischarging {
            return flow.batteryWatts.map(formatPower) ?? "电池输出"
        }
        if flow.isPluggedIn {
            return flow.systemWatts.map(formatPower) ?? flow.adapterWatts.map(formatPower) ?? "直接供电"
        }
        return stateText
    }

    private var batteryLabel: String? {
        guard batteryDisplay != "—" else { return nil }
        return "\(batteryDisplay)%"
    }

    private func endpoint(item: PowerEndpointItem, height: CGFloat) -> some View {
        VStack(spacing: 5) {
            Image(systemName: item.symbol)
                .font(.system(size: height < 40 ? 12 : 15, weight: .bold))
            if let label = item.label {
                Text(label)
                    .font(MonitorFont.helvetica(size: height < 40 ? 9 : 11, bold: true))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(item.tint)
        .frame(width: 48, height: height)
        .background(
            RoundedRectangle(cornerRadius: height < 40 ? 10 : 14, style: .continuous)
                .fill(palette.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: height < 40 ? 10 : 14, style: .continuous)
                        .stroke(Color.white.opacity(palette.isDark ? 0.10 : 0.45), lineWidth: 0.6)
                )
        )
        .shadow(color: Color.black.opacity(palette.isDark ? 0.22 : 0.13), radius: palette.isDark ? 5 : 8, x: 0, y: palette.isDark ? 2 : 4)
    }

    private func nodeHeight(for count: Int) -> CGFloat {
        count == 1 ? 72 : 32
    }

    private func nodeY(index: Int, count: Int) -> CGFloat {
        if count <= 1 { return 0 }
        return index == 0 ? 0 : 40
    }

    private func destinationNodeHeight(index: Int) -> CGFloat {
        guard destinationItems.count > 1,
              let route = flowRoutes.first(where: { $0.destinationIndex == index })
        else { return nodeHeight(for: destinationItems.count) }
        return proportionalRouteFrame(route).height
    }

    private func destinationNodeY(index: Int) -> CGFloat {
        guard destinationItems.count > 1,
              let route = flowRoutes.first(where: { $0.destinationIndex == index })
        else { return nodeY(index: index, count: destinationItems.count) }
        return proportionalRouteFrame(route).minY
    }

    private func routeMidY(_ route: PowerFlowRoute) -> CGFloat {
        if flowRoutes.count > 1 {
            return proportionalRouteFrame(route).midY
        }
        let sourceY = nodeY(index: route.sourceIndex, count: sourceItems.count) + nodeHeight(for: sourceItems.count) / 2
        let destinationY = nodeY(index: route.destinationIndex, count: destinationItems.count) + nodeHeight(for: destinationItems.count) / 2
        return (sourceY + destinationY) / 2
    }

    private func proportionalRouteFrame(_ route: PowerFlowRoute) -> CGRect {
        let gap: CGFloat = 5
        let availableHeight = max(72 - gap * CGFloat(flowRoutes.count - 1), 1)
        let weights = normalizedRouteWeights
        var y: CGFloat = 0
        for current in flowRoutes {
            let height = max(availableHeight * (weights[current.id] ?? (1 / CGFloat(flowRoutes.count))), 12)
            if current.id == route.id {
                return CGRect(x: 0, y: y, width: 1, height: height)
            }
            y += height + gap
        }
        return CGRect(x: 0, y: 0, width: 1, height: availableHeight / CGFloat(flowRoutes.count))
    }

    private var normalizedRouteWeights: [UUID: CGFloat] {
        let raw = flowRoutes.map { max(CGFloat($0.watts ?? 0), 0) }
        let fallback = raw.allSatisfy { $0 <= 0 }
        let effective = fallback ? Array(repeating: CGFloat(1), count: flowRoutes.count) : raw.map { max($0, 0.1) }
        let total = max(effective.reduce(0, +), 1)
        var result: [UUID: CGFloat] = [:]
        for (index, route) in flowRoutes.enumerated() {
            result[route.id] = effective[index] / total
        }
        return result
    }

    private func formatPower(_ watts: Double) -> String {
        if watts >= 10 {
            return "\(Int(watts.rounded())) W"
        }
        return String(format: "%.1f W", watts)
    }
}

private struct PowerEndpointItem: Identifiable {
    let id = UUID()
    let symbol: String
    let label: String?
    let tint: Color
}

private struct PowerFlowRow: Identifiable {
    let id = UUID()
    let powerText: String
}

private struct PowerFlowRoute: Identifiable {
    let id = UUID()
    let sourceIndex: Int
    let destinationIndex: Int
    let watts: Double?
    let powerText: String
}

private struct SankeyPowerBands: View {
    @Environment(\.dashboardPalette) private var palette
    @State private var phase: Double = 0
    let routes: [PowerFlowRoute]
    let sourceCount: Int
    let destinationCount: Int

    var body: some View {
        Canvas { context, size in
            for route in routes {
                let edges = bandEdges(for: route)
                let basePath = bandPath(width: size.width, sourceTop: edges.sourceTop, sourceBottom: edges.sourceBottom, destinationTop: edges.destinationTop, destinationBottom: edges.destinationBottom)
                let minY = min(edges.sourceTop, edges.destinationTop)
                let maxY = max(edges.sourceBottom, edges.destinationBottom)
                let midY = (minY + maxY) / 2
                context.fill(basePath, with: .linearGradient(baseGradient, startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: size.width, y: midY)))
                context.stroke(basePath, with: .color(Color.white.opacity(palette.isDark ? 0.16 : 0.42)), lineWidth: 0.6)

                let glowWidth = max(size.width * 0.22, 34)
                let glowX = -glowWidth + (size.width + glowWidth * 2) * phase
                var glowContext = context
                glowContext.clip(to: basePath)
                glowContext.addFilter(.blur(radius: routes.count == 1 ? 8 : 5))
                glowContext.fill(
                    Path(CGRect(x: glowX, y: minY - 10, width: glowWidth, height: maxY - minY + 20)),
                    with: .linearGradient(glowGradient, startPoint: CGPoint(x: glowX, y: midY), endPoint: CGPoint(x: glowX + glowWidth, y: midY))
                )
            }
        }
        .shadow(color: Color.black.opacity(palette.isDark ? 0.24 : 0.14), radius: palette.isDark ? 5 : 8, x: 0, y: palette.isDark ? 2 : 4)
        .onAppear {
            phase = 0
            withAnimation(.linear(duration: 5.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var baseGradient: Gradient {
        Gradient(colors: [
            palette.orange.opacity(palette.isDark ? 0.62 : 0.48),
            palette.accent.opacity(palette.isDark ? 0.52 : 0.42),
            palette.blue.opacity(palette.isDark ? 0.60 : 0.48)
        ])
    }

    private var glowGradient: Gradient {
        Gradient(colors: [
            Color.clear,
            palette.orange.opacity(palette.isDark ? 0.16 : 0.22),
            Color.white.opacity(palette.isDark ? 0.34 : 0.54),
            palette.blue.opacity(palette.isDark ? 0.20 : 0.28),
            Color.clear
        ])
    }

    private func bandEdges(for route: PowerFlowRoute) -> (sourceTop: CGFloat, sourceBottom: CGFloat, destinationTop: CGFloat, destinationBottom: CGFloat) {
        let source = laneFrame(index: route.sourceIndex, count: sourceCount, opposingCount: destinationCount, opposingIndex: route.destinationIndex, route: route)
        let destination = laneFrame(index: route.destinationIndex, count: destinationCount, opposingCount: sourceCount, opposingIndex: route.sourceIndex, route: route)
        return (source.minY, source.maxY, destination.minY, destination.maxY)
    }

    private func bandPath(width: CGFloat, sourceTop: CGFloat, sourceBottom: CGFloat, destinationTop: CGFloat, destinationBottom: CGFloat) -> Path {
        var path = Path()
        let curve = width * 0.42
        let startTop = CGPoint(x: 0, y: sourceTop)
        let startBottom = CGPoint(x: 0, y: sourceBottom)
        let endTop = CGPoint(x: width, y: destinationTop)
        let endBottom = CGPoint(x: width, y: destinationBottom)

        path.move(to: startTop)
        path.addCurve(to: endTop, control1: CGPoint(x: curve, y: sourceTop), control2: CGPoint(x: width - curve, y: destinationTop))
        path.addLine(to: endBottom)
        path.addCurve(to: startBottom, control1: CGPoint(x: width - curve, y: destinationBottom), control2: CGPoint(x: curve, y: sourceBottom))
        path.closeSubpath()
        return path
    }

    private func laneFrame(index: Int, count: Int, opposingCount: Int, opposingIndex: Int, route: PowerFlowRoute) -> CGRect {
        if count == 1, opposingCount > 1 {
            return proportionalLaneFrame(for: route)
        }
        if count > 1 {
            return proportionalLaneFrame(for: route)
        }
        let height: CGFloat = 72
        let y: CGFloat = count == 1 ? 0 : (index == 0 ? 0 : 40)
        return CGRect(x: 0, y: y, width: 1, height: height)
    }

    private func proportionalLaneFrame(for route: PowerFlowRoute) -> CGRect {
        guard routes.count > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 72)
        }
        let gap: CGFloat = 5
        let availableHeight = max(72 - gap * CGFloat(routes.count - 1), 1)
        let weights = normalizedWeights
        var y: CGFloat = 0
        for current in routes {
            let height = availableHeight * (weights[current.id] ?? (1 / CGFloat(routes.count)))
            if current.id == route.id {
                return CGRect(x: 0, y: y, width: 1, height: max(height, 12))
            }
            y += max(height, 12) + gap
        }
        return CGRect(x: 0, y: 0, width: 1, height: availableHeight / CGFloat(routes.count))
    }

    private var normalizedWeights: [UUID: CGFloat] {
        let raw = routes.map { max(CGFloat($0.watts ?? 0), 0) }
        let fallback = raw.allSatisfy { $0 <= 0 }
        let effective = fallback ? Array(repeating: CGFloat(1), count: routes.count) : raw.map { max($0, 0.1) }
        let total = max(effective.reduce(0, +), 1)
        var result: [UUID: CGFloat] = [:]
        for (index, route) in routes.enumerated() {
            result[route.id] = effective[index] / total
        }
        return result
    }
}

private struct AnimatedPowerBand: View {
    @Environment(\.dashboardPalette) private var palette
    let text: String
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.8) / 4.8
                let glowWidth = max(width * 0.34, 48)
                let xOffset = -glowWidth + (width + glowWidth * 2) * phase

                ZStack {
                    RoundedRectangle(cornerRadius: height < 40 ? 8 : 12, style: .continuous)
                        .fill(palette.controlBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: height < 40 ? 8 : 12, style: .continuous)
                                .stroke(Color.white.opacity(palette.isDark ? 0.14 : 0.50), lineWidth: 0.7)
                        )
                    fullBandGradient(width: width)
                        .opacity(palette.isDark ? 0.58 : 0.46)
                    movingGlow(width: glowWidth)
                        .offset(x: xOffset - width / 2)
                    Text(text)
                        .font(MonitorFont.helvetica(size: height < 40 ? 10 : 13, bold: true))
                        .foregroundStyle(palette.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.chipBackground.opacity(palette.isDark ? 0.18 : 0.34))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height < 40 ? 8 : 12, style: .continuous))
            .shadow(color: Color.black.opacity(palette.isDark ? 0.24 : 0.16), radius: palette.isDark ? 5 : 9, x: 0, y: palette.isDark ? 2 : 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func fullBandGradient(width: CGFloat) -> some View {
        LinearGradient(
            colors: [
                palette.orange.opacity(palette.isDark ? 0.88 : 0.78),
                palette.accent.opacity(palette.isDark ? 0.84 : 0.74),
                palette.blue.opacity(palette.isDark ? 0.88 : 0.78)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width, height: height)
    }

    private func movingGlow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height < 40 ? 8 : 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        palette.orange.opacity(palette.isDark ? 0.12 : 0.18),
                        Color.white.opacity(palette.isDark ? 0.28 : 0.46),
                        palette.blue.opacity(palette.isDark ? 0.16 : 0.24),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .blur(radius: height < 40 ? 5 : 8)
            .frame(width: width, height: height)
    }

}

private struct BatteryRing: View {
    @Environment(\.dashboardPalette) private var palette
    let percent: Int?
    let charging: Bool

    private var fraction: Double {
        min(max(Double(percent ?? 0) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.chipBackground, lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(charging ? palette.accent : palette.sand, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: charging ? "bolt.fill" : "battery.75")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(charging ? palette.accent : palette.secondaryText)
        }
        .frame(width: 40, height: 40)
    }
}

private struct AccessoryBatteryRing: View {
    @Environment(\.dashboardPalette) private var palette
    let accessory: AccessoryBatterySnapshot

    private var fraction: Double {
        min(max(Double(accessory.percentage) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.chipBackground, lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(palette.accent.opacity(0.90), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: accessory.symbolName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.secondaryText)
        }
        .frame(width: 40, height: 40)
        .help("\(accessory.name) \(accessory.percentage)%")
    }
}

private struct SettingsOptionRow<Content: View>: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(palette.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content }
            }
        }
    }
}

private struct SettingsToggleRow: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isOn ? palette.accent : palette.secondaryText)
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)

                Spacer(minLength: 0)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(isOn ? palette.accent.opacity(0.82) : palette.chipBackground)
                    Circle()
                        .fill(isOn ? palette.onAccent : palette.secondaryText.opacity(0.72))
                        .padding(3)
                }
                .frame(width: 40, height: 22)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(palette.chipBackground.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsIntervalRow: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let symbol: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 0)

            Button {
                onChange(max(range.lowerBound, value - step))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(value <= range.lowerBound ? palette.secondaryText.opacity(0.35) : palette.secondaryText)
            .disabled(value <= range.lowerBound)

            Text("\(value)s")
                .font(MonitorFont.helvetica(size: 11, bold: true))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .frame(width: 38)

            Button {
                onChange(min(range.upperBound, value + step))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .heavy))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(value >= range.upperBound ? palette.secondaryText.opacity(0.35) : palette.secondaryText)
            .disabled(value >= range.upperBound)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(palette.chipBackground.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SettingsInfoRow: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(palette.chipBackground.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CapsuleOption: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(selected ? palette.onAccent : palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? palette.accent : palette.chipBackground)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ColorDotOption: View {
    @Environment(\.dashboardPalette) private var palette
    let title: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(selected ? palette.primaryText : palette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? color.opacity(0.24) : palette.chipBackground)
            .overlay(Capsule(style: .continuous).strokeBorder(selected ? color.opacity(0.75) : Color.clear, lineWidth: 0.8))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardProgressStyle: ProgressViewStyle {
    @Environment(\.dashboardPalette) private var palette
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.chipBackground)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 7)
    }
}

#Preview("Dashboard Light") {
    ContentView(viewModel: .preview)
        .preferredColorScheme(.light)
}

#Preview("Dashboard Dark") {
    ContentView(viewModel: .preview)
        .preferredColorScheme(.dark)
}

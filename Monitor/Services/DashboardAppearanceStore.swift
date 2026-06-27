import AppKit
import SwiftUI

enum DashboardAppearanceStorage {
    static let appearanceKey = "HycoDashboard.appearanceMode"
    static let themeKey = "HycoDashboard.themeStyle"
    static let accentKey = "HycoDashboard.accentStyle"
}

enum DashboardAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "自动"
        case .light: return "日间"
        case .dark: return "夜间"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        preferredColorScheme ?? system
    }

    @MainActor
    func applyToApplication() {
        NSApp.appearance = nsAppearance
    }
}

enum DashboardThemeStyle: String, CaseIterable, Identifiable {
    case amber
    case graphite
    case ocean
    case forest
    case plum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amber: return "琥珀"
        case .graphite: return "石墨"
        case .ocean: return "海蓝"
        case .forest: return "森林"
        case .plum: return "紫梅"
        }
    }

    var previewColor: Color {
        switch self {
        case .amber: return Color(red: 0.55, green: 0.39, blue: 0.13)
        case .graphite: return Color(red: 0.30, green: 0.31, blue: 0.34)
        case .ocean: return Color(red: 0.10, green: 0.36, blue: 0.56)
        case .forest: return Color(red: 0.18, green: 0.43, blue: 0.30)
        case .plum: return Color(red: 0.42, green: 0.25, blue: 0.52)
        }
    }

    func panelGradient(isDark: Bool) -> LinearGradient {
        let colors: [Color]
        switch (self, isDark) {
        case (.amber, true):
            colors = [Color(red: 0.27, green: 0.22, blue: 0.08), Color(red: 0.11, green: 0.11, blue: 0.13)]
        case (.amber, false):
            colors = [Color(red: 1.00, green: 0.94, blue: 0.79), Color(red: 0.96, green: 0.90, blue: 0.78)]
        case (.graphite, true):
            colors = [Color(red: 0.15, green: 0.15, blue: 0.17), Color(red: 0.07, green: 0.07, blue: 0.08)]
        case (.graphite, false):
            colors = [Color(red: 0.94, green: 0.95, blue: 0.97), Color(red: 0.86, green: 0.88, blue: 0.91)]
        case (.ocean, true):
            colors = [Color(red: 0.05, green: 0.20, blue: 0.32), Color(red: 0.06, green: 0.10, blue: 0.16)]
        case (.ocean, false):
            colors = [Color(red: 0.83, green: 0.94, blue: 1.00), Color(red: 0.70, green: 0.86, blue: 0.96)]
        case (.forest, true):
            colors = [Color(red: 0.07, green: 0.23, blue: 0.15), Color(red: 0.08, green: 0.11, blue: 0.09)]
        case (.forest, false):
            colors = [Color(red: 0.84, green: 0.96, blue: 0.88), Color(red: 0.76, green: 0.88, blue: 0.78)]
        case (.plum, true):
            colors = [Color(red: 0.22, green: 0.11, blue: 0.30), Color(red: 0.10, green: 0.08, blue: 0.13)]
        case (.plum, false):
            colors = [Color(red: 0.95, green: 0.88, blue: 1.00), Color(red: 0.87, green: 0.80, blue: 0.95)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

enum DashboardAccentStyle: String, CaseIterable, Identifiable {
    case mint
    case blue
    case orange
    case rose
    case violet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mint: return "薄荷"
        case .blue: return "蓝色"
        case .orange: return "橙色"
        case .rose: return "玫瑰"
        case .violet: return "紫色"
        }
    }

    var color: Color {
        switch self {
        case .mint: return Color(red: 0.26, green: 0.86, blue: 0.72)
        case .blue: return Color(red: 0.16, green: 0.58, blue: 1.00)
        case .orange: return Color(red: 0.98, green: 0.62, blue: 0.28)
        case .rose: return Color(red: 0.95, green: 0.36, blue: 0.48)
        case .violet: return Color(red: 0.66, green: 0.48, blue: 1.00)
        }
    }
}

struct DashboardPalette {
    let isDark: Bool
    let panelBackground: LinearGradient
    let cardBackground: LinearGradient
    let chipBackground: Color
    let controlBackground: Color
    let border: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let onAccent: Color
    let accent: Color
    let mint: Color
    let orange: Color
    let sand: Color
    let blue: Color
    let cyan: Color
    let red: Color

    static func resolve(colorScheme: ColorScheme, theme: DashboardThemeStyle, accent: DashboardAccentStyle) -> DashboardPalette {
        let isDark = colorScheme == .dark
        let accentColor = accent.color
        return DashboardPalette(
            isDark: isDark,
            panelBackground: theme.panelGradient(isDark: isDark),
            cardBackground: LinearGradient(
                colors: isDark
                    ? [Color.white.opacity(0.055), Color.black.opacity(0.10)]
                    : [Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.82), Color(red: 0.95, green: 0.97, blue: 1.0).opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            chipBackground: isDark ? Color.white.opacity(0.075) : Color.white.opacity(0.72),
            controlBackground: isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.78),
            border: isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.045),
            primaryText: isDark ? Color(red: 0.96, green: 0.95, blue: 0.94) : Color(red: 0.10, green: 0.11, blue: 0.13),
            secondaryText: isDark ? Color(red: 0.69, green: 0.67, blue: 0.64) : Color(red: 0.39, green: 0.40, blue: 0.43),
            tertiaryText: isDark ? Color(red: 0.50, green: 0.49, blue: 0.48) : Color(red: 0.58, green: 0.59, blue: 0.61),
            onAccent: isDark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color.white,
            accent: accentColor,
            mint: accentColor,
            orange: Color(red: 0.98, green: 0.66, blue: 0.34),
            sand: isDark ? Color(red: 0.92, green: 0.79, blue: 0.53) : Color(red: 0.62, green: 0.43, blue: 0.12),
            blue: Color(red: 0.35, green: 0.58, blue: 0.88),
            cyan: Color(red: 0.16, green: 0.64, blue: 1.0),
            red: Color(red: 0.91, green: 0.39, blue: 0.40)
        )
    }

    static let fallback = DashboardPalette.resolve(colorScheme: .dark, theme: .amber, accent: .mint)
}

private struct DashboardPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: DashboardPalette = .fallback
}

extension EnvironmentValues {
    var dashboardPalette: DashboardPalette {
        get { self[DashboardPaletteEnvironmentKey.self] }
        set { self[DashboardPaletteEnvironmentKey.self] = newValue }
    }
}

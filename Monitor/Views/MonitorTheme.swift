import SwiftUI

// MARK: - Layout Constants

enum MonitorPanelLayout {
    /// 参考图 2 的纵向仪表盘比例，主界面只放监控与快捷操作；外观配置改为弹出设置层。
    static let scale: CGFloat = 1.0

    static let designWidth: CGFloat = 360
    static let designHeight: CGFloat = 815

    static var panelWidth: CGFloat { (designWidth * scale).rounded(.toNearestOrAwayFromZero) }
    static var panelHeight: CGFloat { (designHeight * scale).rounded(.toNearestOrAwayFromZero) }

    static let contentPadding: CGFloat = 14
    static var contentAreaWidth: CGFloat { designWidth - (contentPadding * 2) }
    static let horizontalPadding: CGFloat = contentPadding
    static let verticalTopPadding: CGFloat = contentPadding
    static let verticalBottomPadding: CGFloat = contentPadding

    static let cardSpacing: CGFloat = 8

    static let cardWidth: CGFloat =
        (designWidth - (contentPadding * 2) - cardSpacing) / 2
    static let metricCardHeight: CGFloat = 124
    static let batteryCardHeight: CGFloat = 126
    static let batteryAccessoryRowHeight: CGFloat = 25
    static let batteryAccessoryRowSpacing: CGFloat = 5
    static let processCardHeight: CGFloat = 154
    static let footerActionsHeight: CGFloat = 0
    static let topGridCardHeight: CGFloat = metricCardHeight
    static let bottomGridCardHeight: CGFloat = metricCardHeight
    static let soundCardContentHeight: CGFloat = 114.5
    static var soundCardHeight: CGFloat {
        CardRhythm.cardInset.top + soundCardContentHeight + CardRhythm.cardInset.bottom
    }
    static let headerHeight: CGFloat = 66
    static let footerHeight: CGFloat = footerActionsHeight
    static let chargingPowerCapsuleContentWidth: CGFloat = 88

    static var upperCardsHeight: CGFloat {
        metricCardHeight * 2 + cardSpacing
    }

    static var monitorCardsHeight: CGFloat {
        metricCardHeight * 3 + cardSpacing * 2
    }

    static var contentHeight: CGFloat { designHeight - (contentPadding * 2) }
}

/// 卡片内部排版节奏
enum CardRhythm {
    static let titleGap: CGFloat = 8
    static let sectionGap: CGFloat = 11
    static let itemGap: CGFloat = 7
    static let rowGap: CGFloat = 6
    static let labelGap: CGFloat = 4
    static let memoryHeaderBottomSpacing: CGFloat = titleGap
    static let memoryRowMinHeight: CGFloat = 31
    static let cardInset = EdgeInsets(top: 12, leading: 13, bottom: 13, trailing: 13)
}

/// 全界面统一视觉参数
enum MonitorTheme {
    static let borderLineWidth: CGFloat = 0.5

    static let panelCornerRadius: CGFloat = 22
    static let cardCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 9
    static let minorCornerRadius: CGFloat = 6

    static var scaledPanelCornerRadius: CGFloat {
        (panelCornerRadius * MonitorPanelLayout.scale).rounded(.toNearestOrAwayFromZero)
    }

    static func continuousRect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    static var panelShape: RoundedRectangle { continuousRect(panelCornerRadius) }
    static var cardShape: RoundedRectangle { continuousRect(cardCornerRadius) }
    static var controlShape: RoundedRectangle { continuousRect(controlCornerRadius) }
    static var minorShape: RoundedRectangle { continuousRect(minorCornerRadius) }
    static var scaledPanelShape: RoundedRectangle { continuousRect(scaledPanelCornerRadius) }
    static var capsuleShape: Capsule { Capsule(style: .continuous) }

    static func panelBorderGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.08), Color.white.opacity(0.025)]
                : [Color.white.opacity(0.38), Color.white.opacity(0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func cardBorderGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.09), Color.white.opacity(0.025)]
                : [Color.white.opacity(0.34), Color.white.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func menuListBorderGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.18), Color.white.opacity(0.07)]
                : [Color.white.opacity(0.62), Color.black.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func controlBorderColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    static func subtleBorderColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035)
    }

    static let capsuleTrackHeight: CGFloat = 8
    static let sliderTrackHeight: CGFloat = 9
    static let sectionTitleTracking: CGFloat = 1.1

    static func sectionTitleTracking(for language: AppLanguage) -> CGFloat {
        language == .eng ? 0 : sectionTitleTracking
    }

    static func accentColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.64, blue: 1.0) : Color(red: 0.0, green: 0.48, blue: 1.0)
    }
}

/// 暗色模式统一色板
enum MonitorDarkPalette {
    static let panelBase = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let cardBase = Color(red: 0.09, green: 0.09, blue: 0.10)

    static let panelOverlayOpacity: Double = 0.66
    static let panelSheenOpacity: Double = 0.016
    static let cardSurfaceOpacity: Double = 0.38
    static let cardSheenOpacity: Double = 0.018
    static let controlFill = Color.white.opacity(0.065)
    static let iconButtonOverlay = cardBase.opacity(0.38)
    static let cardDivider = Color.white.opacity(0.08)
    static let neutralButtonFill = Color.white.opacity(0.06)
    static let languageTrackFill = cardBase.opacity(0.30)
    static let languageSelectedFill = cardBase.opacity(0.40)
    static let menuListOverlayOpacity: Double = 0.30
    static let sliderTrackFill = Color.white.opacity(0.10)
    static let valuePillFill = Color.white.opacity(0.08)
    static let progressTrackFill = Color.white.opacity(0.10)
}

/// 浅色模式统一色板
enum MonitorLightPalette {
    static let panelBase = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let cardBase = Color.white

    static let panelOverlayOpacity: Double = 0.50
    static let panelSheenOpacity: Double = 0.075
    static let cardSurfaceOpacity: Double = 0.36
    static let cardSheenOpacity: Double = 0.06
    static let controlFill = Color.black.opacity(0.045)
    static let iconButtonOverlay = Color.white.opacity(0.58)
    static let languageTrackFill = Color.white.opacity(0.24)
    static let languageSelectedFill = Color.white.opacity(0.34)
    static let menuListOverlayOpacity: Double = 0.22
}

extension View {
    func monitorControlShadow(colorScheme: ColorScheme) -> some View {
        shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.028),
            radius: colorScheme == .dark ? 3 : 2,
            x: 0,
            y: colorScheme == .dark ? 1 : 0.5
        )
    }

    func monitorCardShadow(colorScheme: ColorScheme) -> some View {
        shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.035),
            radius: colorScheme == .dark ? 2.5 : 2.2,
            x: 0,
            y: colorScheme == .dark ? 1.4 : 0.8
        )
    }

    func monitorMenuListShadow(colorScheme: ColorScheme) -> some View {
        shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.44 : 0.16),
            radius: colorScheme == .dark ? 14 : 12,
            x: 0,
            y: colorScheme == .dark ? 6 : 5
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.07),
            radius: 2,
            x: 0,
            y: 1
        )
    }

    func monitorCardCell(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height, alignment: .topLeading)
    }

    func monitorCardRowSlot(height: CGFloat) -> some View {
        frame(height: height, alignment: .topLeading)
    }
}

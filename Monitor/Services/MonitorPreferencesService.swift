import AppKit
import Foundation

enum MonitorAppearance: String {
    case light
    case dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 用户界面偏好（语言、浅暗色），持久化于 UserDefaults
enum MonitorPreferencesService {
    nonisolated private static let languageKey = "appLanguage"
    nonisolated private static let appearanceKey = "appearanceMode"
    nonisolated static let powerRefreshIntervalKey = "powerRefreshInterval"
    nonisolated static let bluetoothRefreshIntervalKey = "bluetoothRefreshInterval"

    nonisolated static let defaultPowerRefreshInterval: TimeInterval = 10
    nonisolated static let defaultBluetoothRefreshInterval: TimeInterval = 45

    nonisolated static func savedLanguage() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: languageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .chs
        }
        return language
    }

    nonisolated static func saveLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
    }

    nonisolated static func savedAppearance() -> MonitorAppearance? {
        guard let raw = UserDefaults.standard.string(forKey: appearanceKey),
              let appearance = MonitorAppearance(rawValue: raw) else {
            return nil
        }
        return appearance
    }

    nonisolated static func saveAppearance(_ appearance: MonitorAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
    }

    nonisolated static func powerRefreshInterval() -> TimeInterval {
        boundedInterval(
            UserDefaults.standard.double(forKey: powerRefreshIntervalKey),
            defaultValue: defaultPowerRefreshInterval,
            range: 3...60
        )
    }

    nonisolated static func bluetoothRefreshInterval() -> TimeInterval {
        boundedInterval(
            UserDefaults.standard.double(forKey: bluetoothRefreshIntervalKey),
            defaultValue: defaultBluetoothRefreshInterval,
            range: 15...180
        )
    }

    nonisolated static func savePowerRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(boundedInterval(interval, defaultValue: defaultPowerRefreshInterval, range: 3...60), forKey: powerRefreshIntervalKey)
    }

    nonisolated static func saveBluetoothRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(boundedInterval(interval, defaultValue: defaultBluetoothRefreshInterval, range: 15...180), forKey: bluetoothRefreshIntervalKey)
    }

    @MainActor
    static func applyAppearance(_ appearance: MonitorAppearance) {
        NSApp.appearance = appearance.nsAppearance
    }

    @MainActor
    static func applySystemAppearance() {
        NSApp.appearance = nil
    }

    @MainActor
    static func applySavedAppearance() {
        if let appearance = savedAppearance() {
            applyAppearance(appearance)
        } else {
            applySystemAppearance()
        }
    }

    nonisolated static func clearAll() {
        UserDefaults.standard.removeObject(forKey: languageKey)
        UserDefaults.standard.removeObject(forKey: appearanceKey)
        UserDefaults.standard.removeObject(forKey: powerRefreshIntervalKey)
        UserDefaults.standard.removeObject(forKey: bluetoothRefreshIntervalKey)
    }

    nonisolated private static func boundedInterval(_ value: TimeInterval, defaultValue: TimeInterval, range: ClosedRange<TimeInterval>) -> TimeInterval {
        let candidate = value > 0 ? value : defaultValue
        return min(max(candidate, range.lowerBound), range.upperBound)
    }
}

import AppKit
import Foundation
import ServiceManagement

/// 隐藏/显示桌面图标，实现方式与 One Switch、OnlySwitch 一致：
/// 修改 Finder 的 `CreateDesktop` 偏好并重启 Finder，桌面只保留壁纸，文件仍位于 ~/Desktop。
enum SystemToolsService {

    nonisolated static func isDesktopHidden() -> Bool {
        // 未设置该键时 Finder 默认显示桌面图标。
        guard let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) else { return false }
        if let boolValue = value as? Bool { return !boolValue }
        if let numberValue = value as? NSNumber { return numberValue.intValue == 0 }
        if let stringValue = value as? String { return stringValue == "0" || stringValue.caseInsensitiveCompare("false") == .orderedSame }
        return false
    }

    /// 打开系统设置中的网络（优先跳转 Wi-Fi 页面）。
    nonisolated static func openNetworkSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Network-Settings.extension?Wi-Fi",
            "x-apple.systempreferences:com.apple.Network-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.network"
        ]

        DispatchQueue.main.async {
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                if NSWorkspace.shared.open(url) { return }
            }
        }
    }

    /// 打开系统设置中的存储空间。
    nonisolated static func openStorageSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.StorageManagement-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.storage"
        ]

        DispatchQueue.main.async {
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                if NSWorkspace.shared.open(url) { return }
            }
        }
    }

    @discardableResult
    nonisolated static func setDesktopHidden(_ hidden: Bool) -> Bool {
        CFPreferencesSetAppValue("CreateDesktop" as CFString, (!hidden) as CFPropertyList, "com.apple.finder" as CFString)
        guard CFPreferencesAppSynchronize("com.apple.finder" as CFString) else { return false }

        // 通过 AppKit 结束 Finder，让系统按需重启并重新读取偏好；避免 defaults/killall 外部命令。
        let finderApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        guard !finderApps.isEmpty else { return true }
        for app in finderApps {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
        return true
    }
}

enum LaunchAtLoginService {
    @MainActor
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @MainActor
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }

            return enabled ? SMAppService.mainApp.status == .enabled : SMAppService.mainApp.status != .enabled
        } catch {
            return false
        }
    }
}

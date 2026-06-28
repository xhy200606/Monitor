import AppKit
import Darwin
import Foundation
import IOKit
import Combine

struct DashboardProcess: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: Int32 { pid }
    var cpuDisplay: String { String(format: "%.1f%%", cpuPercent) }
    var memoryDisplay: String { ByteFormatting.formatBytes(memoryBytes, decimals: memoryBytes >= 1_073_741_824 ? 1 : 0) }
}

struct DashboardMemoryFallback: Sendable {
    let usageFraction: Double
    let usedDisplay: String
    let totalDisplay: String
    let swapDisplay: String
}

struct DashboardStorageFallback: Sendable {
    let usageFraction: Double
    let availableDisplay: String
    let usedDisplay: String
    let totalDisplay: String
}

private struct ProcessUsageSample: Sendable {
    let totalCPUTime: UInt64
    let timestamp: TimeInterval
}

private struct ProcessInstantSample: Sendable {
    let pid: Int32
    let name: String
    let totalCPUTime: UInt64
    let memoryBytes: UInt64
    let timestamp: TimeInterval
}

private enum ProcessUsageCache {
    nonisolated(unsafe) private static var samples: [Int32: ProcessUsageSample] = [:]
    nonisolated private static let lock = NSLock()

    nonisolated static func snapshot() -> [Int32: ProcessUsageSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    nonisolated static func replace(with nextSamples: [Int32: ProcessUsageSample]) {
        lock.lock()
        samples = nextSamples
        lock.unlock()
    }
}

@MainActor
final class DashboardRuntimeViewModel: ObservableObject {
    @Published var headerSummary = "正在读取系统信息…"
    @Published var uptimeDisplay = "—"

    @Published var cpuUsagePercent: Double = 0
    @Published var cpuTemperatureCelsius: Double?
    @Published var cpuLoadDisplay = "0"
    @Published var cpuTemperatureDisplay = "—"

    @Published var gpuUsagePercent: Double?
    @Published var gpuTemperatureCelsius: Double?
    @Published var gpuUsageDisplay = "—"
    @Published var gpuTemperatureDisplay = "—"
    @Published var gpuMemoryDisplay = "—"
    @Published var gpuFrequencyDisplay = "—"
    @Published var gpuPowerDisplay = "—"
    @Published var gpuCoreCount: Int?
    @Published var gpuDataSourceDisplay = "Unavailable"

    @Published var memoryUsageFraction: Double = 0
    @Published var memoryUsedDisplay = "—"
    @Published var memoryTotalDisplay = "—"
    @Published var memorySwapDisplay = "—"

    @Published var storageUsageFraction: Double = 0
    @Published var storageAvailableDisplay = "—"
    @Published var storageUsedDisplay = "—"
    @Published var storageTotalDisplay = "—"

    @Published var uploadSpeedDisplay = "0 B/s"
    @Published var downloadSpeedDisplay = "0 B/s"
    @Published var wifiConnected = false
    @Published var networkKindDisplay = NetworkConnectionKind.offline.rawValue

    @Published var batteryDisplay = "—"
    @Published var batteryPercentage: Int?
    @Published var batteryCharging = false
    @Published var batteryPowerDisplay: String?
    @Published var batteryPowerStateDisplay = "—"
    @Published var batteryPowerFlow = PowerFlowSnapshot.empty
    @Published var accessoryBatteries: [AccessoryBatterySnapshot] = []

    @Published var healthScore = 100
    @Published var topProcesses: [DashboardProcess] = []
    @Published var history: [DashboardHistorySample] = DashboardHistoryStore.load()

    private var timer: DispatchSourceTimer?
    private var isRefreshing = false
    private var isGPURefreshing = false
    private var isProcessRefreshing = false
    private var refreshMode: MonitorRefreshMode = .background
    private var lastGPURefresh: TimeInterval = 0
    private var lastProcessRefresh: TimeInterval = 0
    private var gpuRefreshInterval: TimeInterval { refreshMode.interval }
    private var processRefreshInterval: TimeInterval { refreshMode.interval }

    func start(mode: MonitorRefreshMode = .background, forceRefresh: Bool = false) {
        refreshMode = mode
        MonitorRefreshMode.current = mode
        if forceRefresh {
            lastGPURefresh = 0
            lastProcessRefresh = 0
            refresh()
        }
        restartTimer()
    }

    func setRefreshMode(_ mode: MonitorRefreshMode, forceRefresh: Bool) {
        refreshMode = mode
        MonitorRefreshMode.current = mode
        if forceRefresh {
            lastGPURefresh = 0
            lastProcessRefresh = 0
            refresh()
        }
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        timer = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + refreshMode.interval,
            repeating: refreshMode.interval,
            leeway: .milliseconds(refreshMode == .foreground ? 250 : 1_000)
        )
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DashboardHistoryStore.save(history)
    }

    /// 分两段刷新：基础数据不等待 GPU，避免 IORegistry 在个别系统上阻塞后导致整屏保持 0/—。
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task(priority: .userInitiated) { [weak self] in
            let basic = await Task.detached(priority: .userInitiated) {
                Self.readBasicSnapshot()
            }.value

            guard let self else { return }
            self.applyBasic(basic)
            self.isRefreshing = false
            self.appendHistorySample()
            self.refreshGPUIfNeeded()
            self.refreshProcessesIfNeeded()
        }
    }

    private func refreshGPUIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGPURefresh >= gpuRefreshInterval else { return }
        guard !isGPURefreshing else { return }
        lastGPURefresh = now
        isGPURefreshing = true

        Task(priority: .utility) { [weak self] in
            let gpu = await Task.detached(priority: .utility) {
                GPUMonitor.snapshot()
            }.value

            guard let self else { return }
            self.applyGPU(gpu)
            self.isGPURefreshing = false
            self.refreshHealthScore()
        }
    }

    private func refreshProcessesIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProcessRefresh >= processRefreshInterval else { return }
        guard !isProcessRefreshing else { return }
        lastProcessRefresh = now
        isProcessRefreshing = true

        Task(priority: .utility) { [weak self] in
            let processes = await Task.detached(priority: .utility) {
                Self.readTopProcesses()
            }.value

            guard let self else { return }
            self.topProcesses = processes
            self.isProcessRefreshing = false
        }
    }

    private func applyBasic(_ snapshot: BasicDashboardSnapshot) {
        headerSummary = snapshot.headerSummary
        uptimeDisplay = snapshot.uptimeDisplay

        cpuUsagePercent = snapshot.cpuUsagePercent
        cpuLoadDisplay = ByteFormatting.formatPercent(snapshot.cpuUsagePercent)
        cpuTemperatureCelsius = snapshot.cpuTemperatureCelsius
        cpuTemperatureDisplay = ByteFormatting.formatTemperature(snapshot.cpuTemperatureCelsius)

        memoryUsageFraction = snapshot.memory.usageFraction
        memoryUsedDisplay = snapshot.memory.usedDisplay
        memoryTotalDisplay = snapshot.memory.totalDisplay
        memorySwapDisplay = snapshot.memory.swapDisplay

        storageUsageFraction = snapshot.storage.usageFraction
        storageAvailableDisplay = snapshot.storage.availableDisplay
        storageUsedDisplay = snapshot.storage.usedDisplay
        storageTotalDisplay = snapshot.storage.totalDisplay

        uploadSpeedDisplay = snapshot.uploadSpeedDisplay
        downloadSpeedDisplay = snapshot.downloadSpeedDisplay
        wifiConnected = snapshot.wifiConnected
        networkKindDisplay = snapshot.networkKindDisplay

        batteryDisplay = snapshot.batteryDisplay
        batteryPercentage = snapshot.batteryPercentage
        batteryCharging = snapshot.batteryCharging
        batteryPowerDisplay = snapshot.batteryPowerDisplay
        batteryPowerStateDisplay = snapshot.batteryPowerStateDisplay
        batteryPowerFlow = snapshot.batteryPowerFlow
        accessoryBatteries = snapshot.accessoryBatteries

        refreshHealthScore()
    }

    private func applyGPU(_ gpu: GPUSnapshot) {
        gpuUsagePercent = gpu.usagePercent
        gpuUsageDisplay = gpu.usageDisplay
        gpuTemperatureCelsius = gpu.temperatureCelsius
        gpuTemperatureDisplay = gpu.temperatureDisplay
        gpuMemoryDisplay = gpu.memoryDisplay
        gpuFrequencyDisplay = gpu.frequencyDisplay
        gpuPowerDisplay = gpu.powerDisplay
        gpuCoreCount = gpu.coreCount
        gpuDataSourceDisplay = gpu.dataSource.rawValue
    }

    func terminate(_ process: DashboardProcess) {
        guard process.pid > 0 else { return }
        kill(process.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refreshHealthScore() {
        let temp = max(cpuTemperatureCelsius ?? 0, gpuTemperatureCelsius ?? 0)
        let tempPenalty = max(0, temp - 70) * 0.45
        let cpuPenalty = max(0, cpuUsagePercent - 65) * 0.20
        let memoryPenalty = max(0, memoryUsageFraction * 100 - 75) * 0.14
        let storagePenalty = max(0, storageUsageFraction * 100 - 80) * 0.34
        let gpuPenalty = max(0, (gpuUsagePercent ?? 0) - 75) * 0.12
        healthScore = min(99, max(1, Int((100 - tempPenalty - cpuPenalty - memoryPenalty - storagePenalty - gpuPenalty).rounded())))
    }

    private func appendHistorySample() {
        let sample = DashboardHistorySample(
            cpuUsage: cpuUsagePercent,
            gpuUsage: gpuUsagePercent,
            memoryUsage: memoryUsageFraction * 100,
            storageUsage: storageUsageFraction * 100,
            cpuTemperature: cpuTemperatureCelsius,
            gpuTemperature: gpuTemperatureCelsius,
            uploadKBs: Self.kilobytesPerSecond(from: uploadSpeedDisplay),
            downloadKBs: Self.kilobytesPerSecond(from: downloadSpeedDisplay)
        )
        history = DashboardHistoryStore.appending(sample, to: history)
    }

    // MARK: - Snapshot readers

    nonisolated private static func readBasicSnapshot() -> BasicDashboardSnapshot {
        let cpu = CPUMonitor.snapshot()
        let hardware = HardwareMonitor.snapshot()
        let memorySnapshot = MemoryMonitor.snapshot()
        let storageSnapshot = StorageMonitor.snapshot()
        let memory = DashboardMemoryFallback(
            usageFraction: memorySnapshot.pressureFraction,
            usedDisplay: memorySnapshot.usedDisplay,
            totalDisplay: memorySnapshot.physicalDisplay,
            swapDisplay: memorySnapshot.swapDisplay
        )
        let storage = DashboardStorageFallback(
            usageFraction: storageSnapshot.usageFraction,
            availableDisplay: storageSnapshot.availableDisplay,
            usedDisplay: storageSnapshot.usedDisplay,
            totalDisplay: storageSnapshot.totalDisplay
        )
        let network = NetworkMonitor.snapshot()
        let battery = BatteryMonitor.snapshot()

        return BasicDashboardSnapshot(
            headerSummary: readHeaderSummary(),
            uptimeDisplay: readUptimeDisplay(),
            cpuUsagePercent: cpu.usagePercent,
            cpuTemperatureCelsius: hardware.cpuTemperatureCelsius,
            memory: memory,
            storage: storage,
            uploadSpeedDisplay: network.uploadDisplay,
            downloadSpeedDisplay: network.downloadDisplay,
            wifiConnected: network.isWifiConnected,
            networkKindDisplay: network.connectionKind.rawValue,
            batteryDisplay: battery.displayValue,
            batteryPercentage: battery.percentage,
            batteryCharging: battery.isCharging,
            batteryPowerDisplay: battery.chargingPowerDisplay,
            batteryPowerStateDisplay: battery.powerStateDisplay,
            batteryPowerFlow: battery.powerFlow,
            accessoryBatteries: battery.accessories
        )
    }

    nonisolated private static func readHeaderSummary() -> String {
        let deviceName = Host.current().localizedName ?? "Mac"
        let chipName = readChipName()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return "\(deviceName) · \(chipName) · \(systemVersion)"
    }

    nonisolated private static func readChipName() -> String {
        if let chip = ioPlatformString(forKey: "chip-model"), !chip.isEmpty {
            return chip
        }
        if let brand = sysctlString(forName: "machdep.cpu.brand_string"), !brand.isEmpty {
            return brand.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let model = sysctlString(forName: "hw.model"), !model.isEmpty {
            return model
        }
        return sysctlString(forName: "hw.machine") ?? "Mac"
    }

    nonisolated private static func ioPlatformString(forKey key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    nonisolated private static func sysctlString(forName name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func readTopProcesses() -> [DashboardProcess] {
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let firstPIDs = listedProcessIDs()
        guard !firstPIDs.isEmpty else { return [] }

        let firstTimestamp = ProcessInfo.processInfo.systemUptime
        let firstSamples = processInstantSamples(for: firstPIDs, excluding: currentPID, timestamp: firstTimestamp)
        guard !firstSamples.isEmpty else { return [] }

        let previousSamples = ProcessUsageCache.snapshot()
        let reusablePreviousCount = firstSamples.reduce(0) { count, sample in
            guard let previous = previousSamples[sample.pid], sample.totalCPUTime >= previous.totalCPUTime else { return count }
            let elapsed = sample.timestamp - previous.timestamp
            return elapsed >= 0.75 && elapsed <= 3.75 ? count + 1 : count
        }

        let baselineSamples: [Int32: ProcessUsageSample]
        let finalSamples: [ProcessInstantSample]

        if reusablePreviousCount >= max(6, firstSamples.count / 6) {
            // 前台连续刷新时复用上一帧样本，窗口约等于 2s，更接近活动监视器的实时 %CPU。
            baselineSamples = previousSamples
            finalSamples = firstSamples
        } else {
            // 从后台/首次打开时旧样本会把瞬时 CPU 摊薄；这里主动做一个短窗口采样。
            // 先重新枚举 PID，避免高负载进程在两次采样之间才出现。
            usleep(1_000_000)
            let secondPIDs = listedProcessIDs()
            let secondTimestamp = ProcessInfo.processInfo.systemUptime
            let secondSamples = processInstantSamples(for: secondPIDs.isEmpty ? firstPIDs : secondPIDs, excluding: currentPID, timestamp: secondTimestamp)
            baselineSamples = Dictionary(uniqueKeysWithValues: firstSamples.map {
                ($0.pid, ProcessUsageSample(totalCPUTime: $0.totalCPUTime, timestamp: $0.timestamp))
            })
            finalSamples = secondSamples.isEmpty ? firstSamples : secondSamples
        }

        let nextSamples = Dictionary(uniqueKeysWithValues: finalSamples.map {
            ($0.pid, ProcessUsageSample(totalCPUTime: $0.totalCPUTime, timestamp: $0.timestamp))
        })
        ProcessUsageCache.replace(with: nextSamples)

        let processes = finalSamples.compactMap { sample -> DashboardProcess? in
            guard let previous = baselineSamples[sample.pid],
                  sample.timestamp > previous.timestamp,
                  sample.totalCPUTime >= previous.totalCPUTime
            else { return nil }

            let elapsed = sample.timestamp - previous.timestamp
            guard elapsed > 0 else { return nil }
            // ri_user_time + ri_system_time 是纳秒；100% 表示占满一个 CPU 核心，和活动监视器口径一致。
            let cpuSeconds = Double(sample.totalCPUTime - previous.totalCPUTime) / 1_000_000_000
            let cpuPercent = min(max(cpuSeconds / elapsed * 100, 0), 999)
            guard !sample.name.isEmpty, cpuPercent > 0.05 || sample.memoryBytes > 1_048_576 else { return nil }
            return DashboardProcess(pid: sample.pid, name: sample.name, cpuPercent: cpuPercent, memoryBytes: sample.memoryBytes)
        }

        return processes
            .sorted { lhs, rhs in
                if abs(lhs.cpuPercent - rhs.cpuPercent) < 0.05 {
                    return lhs.memoryBytes > rhs.memoryBytes
                }
                return lhs.cpuPercent > rhs.cpuPercent
            }
            .prefix(5)
            .map { $0 }
    }

    nonisolated private static func processInstantSamples(for pids: [Int32], excluding currentPID: Int32, timestamp: TimeInterval) -> [ProcessInstantSample] {
        var samples: [ProcessInstantSample] = []
        samples.reserveCapacity(min(pids.count, 160))

        for pid in pids where pid > 0 && pid != currentPID {
            guard let allInfo = processAllInfo(for: pid) else { continue }
            guard let usage = processResourceUsage(for: pid, fallbackInfo: allInfo) else { continue }
            let name = processName(from: allInfo, pid: pid)
            guard !name.isEmpty else { continue }
            samples.append(ProcessInstantSample(pid: pid, name: name, totalCPUTime: usage.totalCPUTime, memoryBytes: usage.memoryBytes, timestamp: timestamp))
        }

        return samples
    }

    nonisolated private static func processResourceUsage(for pid: Int32, fallbackInfo: proc_taskallinfo) -> (totalCPUTime: UInt64, memoryBytes: UInt64)? {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { usagePointer -> Int32 in
            let rawPointer = UnsafeMutableRawPointer(usagePointer)
            let rusagePointer = rawPointer.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePointer)
        }
        if usageResult == 0 {
            let total = usage.ri_user_time &+ usage.ri_system_time
            let memory = UInt64(usage.ri_resident_size)
            return (total, memory)
        }

        let taskInfo = fallbackInfo.ptinfo
        let total = taskInfo.pti_total_user &+ taskInfo.pti_total_system
        let memory = UInt64(taskInfo.pti_resident_size)
        return total > 0 ? (total, memory) : nil
    }

    nonisolated private static func listedProcessIDs() -> [Int32] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        let validCount = min(pids.count, Int(bytes) / MemoryLayout<pid_t>.stride)
        var result: [Int32] = []
        result.reserveCapacity(validCount)
        for index in 0..<validCount {
            result.append(Int32(pids[index]))
        }
        return result
    }

    nonisolated private static func processAllInfo(for pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = MemoryLayout<proc_taskallinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, Int32(PROC_PIDTASKALLINFO), 0, pointer, Int32(size))
        }
        return result == Int32(size) ? info : nil
    }

    nonisolated private static func processName(from info: proc_taskallinfo, pid: Int32) -> String {
        let command = withUnsafeBytes(of: info.pbsd.pbi_comm) { rawBuffer -> String in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        if !command.isEmpty { return command }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard result > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: pathBuffer)).lastPathComponent
    }

    nonisolated private static func readUptimeDisplay() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) == 0 else { return "—" }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        let interval = max(0, Int(Date().timeIntervalSince(bootDate)))
        let days = interval / 86_400
        let hours = (interval % 86_400) / 3_600
        let minutes = (interval % 3_600) / 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes)分"
    }

    nonisolated private static func kilobytesPerSecond(from display: String) -> Double {
        let value = firstNumber(in: display) ?? 0
        let lower = display.lowercased()
        if lower.contains("gb/s") { return value * 1024 * 1024 }
        if lower.contains("mb/s") { return value * 1024 }
        if lower.contains("kb/s") { return value }
        return value / 1024
    }

    nonisolated private static func firstNumber(in text: String) -> Double? {
        guard let range = text.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(String(text[range]))
    }
}

private struct BasicDashboardSnapshot: Sendable {
    let headerSummary: String
    let uptimeDisplay: String
    let cpuUsagePercent: Double
    let cpuTemperatureCelsius: Double?
    let memory: DashboardMemoryFallback
    let storage: DashboardStorageFallback
    let uploadSpeedDisplay: String
    let downloadSpeedDisplay: String
    let wifiConnected: Bool
    let networkKindDisplay: String
    let batteryDisplay: String
    let batteryPercentage: Int?
    let batteryCharging: Bool
    let batteryPowerDisplay: String?
    let batteryPowerStateDisplay: String
    let batteryPowerFlow: PowerFlowSnapshot
    let accessoryBatteries: [AccessoryBatterySnapshot]
}

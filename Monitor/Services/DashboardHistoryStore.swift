import Foundation

struct DashboardHistorySample: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let cpuUsage: Double
    let gpuUsage: Double?
    let memoryUsage: Double
    let storageUsage: Double
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let uploadKBs: Double
    let downloadKBs: Double

    init(
        timestamp: Date = Date(),
        cpuUsage: Double,
        gpuUsage: Double?,
        memoryUsage: Double,
        storageUsage: Double,
        cpuTemperature: Double?,
        gpuTemperature: Double?,
        uploadKBs: Double,
        downloadKBs: Double
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
        self.storageUsage = storageUsage
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.uploadKBs = uploadKBs
        self.downloadKBs = downloadKBs
    }
}

enum DashboardHistoryStore {
    private static let maxSamples = 180
    private static let saveInterval: TimeInterval = 30
    nonisolated(unsafe) private static var lastSaveTime: TimeInterval = 0

    static func load() -> [DashboardHistorySample] {
        let url = historyURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let samples = (try? JSONDecoder().decode([DashboardHistorySample].self, from: data)) ?? []
        return Array(samples.suffix(maxSamples))
    }

    @discardableResult
    static func appending(_ sample: DashboardHistorySample, to samples: [DashboardHistorySample]) -> [DashboardHistorySample] {
        var next = samples
        next.append(sample)
        if next.count > maxSamples {
            next.removeFirst(next.count - maxSamples)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSaveTime >= saveInterval {
            save(next)
            lastSaveTime = now
        }
        return next
    }

    static func save(_ samples: [DashboardHistorySample]) {
        let url = historyURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(samples.suffix(maxSamples)))
            try data.write(to: url, options: [.atomic])
        } catch {
            // 监控历史不是核心数据，写入失败时保持 UI 可用。
        }
    }

    private static func historyURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Monitor", isDirectory: true)
            .appendingPathComponent("dashboard-history.json")
    }
}

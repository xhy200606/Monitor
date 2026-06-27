import Foundation
import IOKit

struct GPUSnapshot: Sendable {
    let usagePercent: Double?
    let temperatureCelsius: Double?
    let memoryUsedBytes: UInt64?
    let frequencyMHz: Double?
    let powerWatts: Double?
    let coreCount: Int?
    let dataSource: GPUDataSource

    var usageDisplay: String {
        guard let usagePercent else { return "—" }
        return ByteFormatting.formatPercent(usagePercent)
    }

    var temperatureDisplay: String {
        ByteFormatting.formatTemperature(temperatureCelsius)
    }

    var memoryDisplay: String {
        guard let memoryUsedBytes else { return "—" }
        return ByteFormatting.formatBytes(memoryUsedBytes, decimals: memoryUsedBytes >= 1_073_741_824 ? 1 : 0)
    }

    var frequencyDisplay: String {
        guard let frequencyMHz else { return "—" }
        return frequencyMHz >= 1000
            ? String(format: "%.2f GHz", frequencyMHz / 1000)
            : String(format: "%.0f MHz", frequencyMHz)
    }

    var powerDisplay: String {
        guard let powerWatts else { return "—" }
        return String(format: powerWatts >= 10 ? "%.0f W" : "%.1f W", powerWatts)
    }
}

enum GPUDataSource: String, Sendable {
    case ioRegistry = "IORegistry"
    case unavailable = "Unavailable"
}

private struct GPUMetricBundle: Sendable {
    var usagePercent: Double?
    var temperatureCelsius: Double?
    var memoryUsedBytes: UInt64?
    var frequencyMHz: Double?
    var powerWatts: Double?
    var coreCount: Int?

    nonisolated init(
        usagePercent: Double? = nil,
        temperatureCelsius: Double? = nil,
        memoryUsedBytes: UInt64? = nil,
        frequencyMHz: Double? = nil,
        powerWatts: Double? = nil,
        coreCount: Int? = nil
    ) {
        self.usagePercent = usagePercent
        self.temperatureCelsius = temperatureCelsius
        self.memoryUsedBytes = memoryUsedBytes
        self.frequencyMHz = frequencyMHz
        self.powerWatts = powerWatts
        self.coreCount = coreCount
    }

    nonisolated var hasAnyDynamicMetric: Bool {
        usagePercent != nil || temperatureCelsius != nil || memoryUsedBytes != nil || frequencyMHz != nil || powerWatts != nil
    }

    nonisolated var hasAllDynamicMetrics: Bool {
        usagePercent != nil && memoryUsedBytes != nil && frequencyMHz != nil && powerWatts != nil
    }

    nonisolated mutating func mergeMissing(from other: GPUMetricBundle) {
        usagePercent = usagePercent ?? other.usagePercent
        temperatureCelsius = temperatureCelsius ?? other.temperatureCelsius
        memoryUsedBytes = memoryUsedBytes ?? other.memoryUsedBytes
        frequencyMHz = frequencyMHz ?? other.frequencyMHz
        powerWatts = powerWatts ?? other.powerWatts
        coreCount = coreCount ?? other.coreCount
    }
}

enum GPUMonitor {
    nonisolated(unsafe) private static var cachedCoreCount: Int?

    nonisolated static func snapshot() -> GPUSnapshot {
        let registryMetrics = metricsFromIORegistry()

        let source: GPUDataSource
        if registryMetrics.hasAnyDynamicMetric {
            source = .ioRegistry
        } else {
            source = .unavailable
        }

        return GPUSnapshot(
            usagePercent: registryMetrics.usagePercent,
            temperatureCelsius: GPUTemperatureReader.shared.gpuTemperatureCelsius() ?? registryMetrics.temperatureCelsius,
            memoryUsedBytes: registryMetrics.memoryUsedBytes,
            frequencyMHz: registryMetrics.frequencyMHz,
            powerWatts: registryMetrics.powerWatts,
            coreCount: registryMetrics.coreCount ?? fallbackCoreCountFromChipName(),
            dataSource: source
        )
    }

    // MARK: - IORegistry direct reader

    nonisolated private static func metricsFromIORegistry() -> GPUMetricBundle {
        var bundle = GPUMetricBundle()

        for className in ["IOAccelerator", "IOAccelerator2", "AGXAccelerator", "IOGraphicsAccelerator", "IOGPU"] {
            let services = acceleratorServices(matching: className)
            defer { services.forEach { IOObjectRelease($0) } }

            for service in services {
                let dictionaries = metricDictionaries(from: service)
                for dictionary in dictionaries {
                    let flat = flattened(dictionary)
                    bundle.usagePercent = bundle.usagePercent ?? utilizationPercent(from: flat)
                    bundle.temperatureCelsius = bundle.temperatureCelsius ?? temperatureCelsius(from: flat)
                    bundle.memoryUsedBytes = bundle.memoryUsedBytes ?? memoryBytes(from: flat)
                    bundle.frequencyMHz = bundle.frequencyMHz ?? frequencyMHz(from: flat)
                    bundle.powerWatts = bundle.powerWatts ?? powerWatts(from: flat)
                    bundle.coreCount = bundle.coreCount ?? coreCount(from: flat)
                    if bundle.hasAllDynamicMetrics, bundle.coreCount != nil { break }
                }
                if bundle.hasAllDynamicMetrics, bundle.coreCount != nil { break }
            }
            if bundle.hasAllDynamicMetrics, bundle.coreCount != nil { break }
        }

        if bundle.coreCount == nil {
            bundle.coreCount = cachedCoreCount ?? coreCountFromPlatformRegistry()
            cachedCoreCount = bundle.coreCount
        }

        return bundle
    }

    nonisolated private static func acceleratorServices(matching className: String) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(className) else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [io_registry_entry_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            result.append(service)
        }
        return result
    }

    nonisolated private static func metricDictionaries(from service: io_registry_entry_t) -> [[String: Any]] {
        var dictionaries: [[String: Any]] = []

        if let performance = propertyDictionary(named: "PerformanceStatistics", from: service) {
            dictionaries.append(performance)
        }
        if let statistics = propertyDictionary(named: "Statistics", from: service) {
            dictionaries.append(statistics)
        }

        return dictionaries
    }

    nonisolated private static func propertyDictionary(named name: String, from service: io_registry_entry_t) -> [String: Any]? {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            name as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return value as? [String: Any]
    }

    nonisolated private static func allProperties(from service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dictionary
    }

    nonisolated private static func flattened(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        func walk(prefix: String, value: Any) {
            if let nested = value as? [String: Any] {
                for (key, nestedValue) in nested {
                    walk(prefix: prefix.isEmpty ? key : "\(prefix).\(key)", value: nestedValue)
                }
            } else if let nested = value as? NSDictionary {
                for (key, nestedValue) in nested {
                    guard let key = key as? String else { continue }
                    walk(prefix: prefix.isEmpty ? key : "\(prefix).\(key)", value: nestedValue)
                }
            } else {
                result[prefix] = value
            }
        }
        for (key, value) in dictionary {
            walk(prefix: key, value: value)
        }
        return result
    }

    // MARK: - Metric extraction

    nonisolated private static func utilizationPercent(from values: [String: Any]) -> Double? {
        let preferredKeys = [
            "Device Utilization %",
            "GPU Utilization %",
            "Renderer Utilization %",
            "Tiler Utilization %",
            "GPU Core Utilization %",
            "GPU Busy %"
        ]

        for key in preferredKeys {
            if let direct = firstValue(containing: key, in: values), let percent = normalizedPercent(from: direct) {
                return percent
            }
        }

        let candidates = values.compactMap { key, value -> Double? in
            let lower = key.lowercased()
            guard lower.contains("utilization") || lower.contains("gpu busy") || lower.contains("gpubusy") || lower.contains("renderer busy") || lower.contains("tiler busy") else {
                return nil
            }
            return normalizedPercent(from: value)
        }
        return candidates.max()
    }

    nonisolated private static func temperatureCelsius(from values: [String: Any]) -> Double? {
        let preferredFragments = [
            "gpu temperature",
            "gpu die temperature",
            "agx temperature",
            "device temperature",
            "temperature c",
            "temperature"
        ]

        for fragment in preferredFragments {
            if let pair = firstPair(containing: fragment, in: values),
               let celsius = normalizedTemperatureCelsius(from: pair.value, key: pair.key) {
                return celsius
            }
        }
        return nil
    }

    nonisolated private static func memoryBytes(from values: [String: Any]) -> UInt64? {
        let preferredFragments = [
            "in use video memory",
            "in use system memory",
            "used video memory",
            "used system memory",
            "vramused",
            "vram used",
            "memoryused",
            "gpu memory used",
            "allocated system memory"
        ]

        for fragment in preferredFragments {
            if let pair = firstPair(containing: fragment, in: values), let bytes = normalizedBytes(from: pair.value, key: pair.key) {
                return bytes
            }
        }
        return nil
    }

    nonisolated private static func frequencyMHz(from values: [String: Any]) -> Double? {
        let preferredFragments = [
            "core clock",
            "gpu clock",
            "gpu frequency",
            "core frequency",
            "current frequency",
            "frequency mhz"
        ]

        for fragment in preferredFragments {
            if let pair = firstPair(containing: fragment, in: values), let mhz = normalizedFrequencyMHz(from: pair.value, key: pair.key) {
                return mhz
            }
        }
        return nil
    }

    nonisolated private static func powerWatts(from values: [String: Any]) -> Double? {
        let preferredFragments = [
            "gpu power",
            "gpu package power",
            "device power",
            "instantaneous power",
            "power watts",
            "power(w)",
            "power mw"
        ]

        for fragment in preferredFragments {
            if let pair = firstPair(containing: fragment, in: values), let watts = normalizedPowerWatts(from: pair.value, key: pair.key) {
                return watts
            }
        }
        return nil
    }

    nonisolated private static func coreCount(from values: [String: Any]) -> Int? {
        let preferredFragments = [
            "gpu-core-count",
            "gpu core count",
            "gpu cores",
            "core count"
        ]

        for fragment in preferredFragments {
            if let pair = firstPair(containing: fragment, in: values), let count = positiveInt(from: pair.value), count > 0, count < 256 {
                return count
            }
        }
        return nil
    }

    nonisolated private static func coreCountFromPlatformRegistry() -> Int? {
        guard let matching = IOServiceMatching("IOPlatformExpertDevice") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let props = allProperties(from: service) else { return nil }
        return coreCount(from: flattened(props))
    }

    nonisolated private static func fallbackCoreCountFromChipName() -> Int? {
        let chip = SystemInfoProvider.snapshot().chipName.lowercased()
        if chip.contains("ultra") {
            if chip.contains("m3") || chip.contains("m2") || chip.contains("m1") { return 60 }
        }
        if chip.contains("max") {
            if chip.contains("m4") || chip.contains("m3") { return 40 }
            if chip.contains("m2") || chip.contains("m1") { return 38 }
        }
        if chip.contains("pro") {
            if chip.contains("m4") { return 20 }
            if chip.contains("m3") { return 18 }
            if chip.contains("m2") || chip.contains("m1") { return 19 }
        }
        if chip.contains("m4") || chip.contains("m3") || chip.contains("m2") { return 10 }
        if chip.contains("m1") { return 8 }
        return nil
    }

    // MARK: - Normalizers

    nonisolated private static func firstValue(containing fragment: String, in values: [String: Any]) -> Any? {
        firstPair(containing: fragment, in: values)?.value
    }

    nonisolated private static func firstPair(containing fragment: String, in values: [String: Any]) -> (key: String, value: Any)? {
        let target = fragment.lowercased()
        return values.first { key, _ in
            key.lowercased().contains(target)
        }
    }

    nonisolated private static func normalizedPercent(from rawValue: Any?) -> Double? {
        guard let value = number(from: rawValue), value.isFinite, value >= 0 else { return nil }
        switch value {
        case 0...1:
            return value * 100
        case 0...100:
            return value
        case 100...10_000:
            return value / 100
        default:
            return nil
        }
    }

    nonisolated private static func normalizedBytes(from rawValue: Any?, key: String) -> UInt64? {
        guard let value = number(from: rawValue), value.isFinite, value > 0 else { return nil }
        let lower = key.lowercased()
        let bytes: Double
        if lower.contains("kbytes") || lower.contains(" kb") || lower.contains("_kb") {
            bytes = value * 1024
        } else if lower.contains("mbytes") || lower.contains(" mb") || lower.contains("_mb") {
            bytes = value * 1_048_576
        } else if lower.contains("gbytes") || lower.contains(" gb") || lower.contains("_gb") {
            bytes = value * 1_073_741_824
        } else if value < 1_000_000 {
            // Small memory counters exposed by some drivers are often MB units.
            bytes = value * 1_048_576
        } else {
            bytes = value
        }
        guard bytes > 0, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes.rounded())
    }

    nonisolated private static func normalizedFrequencyMHz(from rawValue: Any?, key: String) -> Double? {
        guard let value = number(from: rawValue), value.isFinite, value > 0 else { return nil }
        let lower = key.lowercased()
        if lower.contains("ghz") { return value * 1000 }
        if lower.contains("khz") { return value / 1000 }
        if lower.contains("hz") && !lower.contains("mhz") { return value / 1_000_000 }
        if value > 1_000_000 { return value / 1_000_000 }
        if value > 10_000 { return value / 1000 }
        return value
    }

    nonisolated private static func normalizedPowerWatts(from rawValue: Any?, key: String) -> Double? {
        guard let value = number(from: rawValue), value.isFinite, value > 0 else { return nil }
        let lower = key.lowercased()
        if lower.contains("uw") || lower.contains("microwatt") { return value / 1_000_000 }
        if lower.contains("mw") || lower.contains("milliwatt") { return value / 1000 }
        if lower.contains("watts") || lower.contains("power(w)") { return value }
        // Many IORegistry power counters are milliwatts when no explicit unit is present.
        return value > 500 ? value / 1000 : value
    }

    nonisolated private static func normalizedTemperatureCelsius(from rawValue: Any?, key: String) -> Double? {
        guard let value = number(from: rawValue), value.isFinite else { return nil }
        let lower = key.lowercased()
        let celsius: Double
        if lower.contains("millidegree") || lower.contains("mc") || lower.contains("milli") || value > 1000 {
            celsius = value / 1000
        } else if lower.contains("kelvin") {
            celsius = value - 273.15
        } else {
            celsius = value
        }
        guard celsius > 0, celsius < 150 else { return nil }
        return celsius
    }

    nonisolated private static func positiveInt(from rawValue: Any?) -> Int? {
        guard let value = number(from: rawValue), value.isFinite, value > 0 else { return nil }
        return Int(value.rounded())
    }

    nonisolated private static func number(from rawValue: Any?) -> Double? {
        if let number = rawValue as? NSNumber { return number.doubleValue }
        if let double = rawValue as? Double { return double }
        if let int = rawValue as? Int { return Double(int) }
        if let int64 = rawValue as? Int64 { return Double(int64) }
        if let uint64 = rawValue as? UInt64 { return Double(uint64) }
        if let string = rawValue as? String {
            let cleaned = string
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned)
        }
        return nil
    }
}

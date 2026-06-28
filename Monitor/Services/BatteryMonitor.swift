import Foundation
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.hid
import IOKit.ps
import ObjectiveC

struct AccessoryBatterySnapshot: Identifiable, Hashable, Sendable {
    let name: String
    let percentage: Int
    let symbolNameOverride: String?

    nonisolated init(name: String, percentage: Int, symbolNameOverride: String? = nil) {
        self.name = name
        self.percentage = percentage
        self.symbolNameOverride = symbolNameOverride
    }

    var id: String { "\(name)-\(percentage)" }

    var symbolName: String {
        if let symbolNameOverride { return symbolNameOverride }
        let lowercasedName = name.lowercased()
        // 先判断键盘/鼠标/触控板，避免第三方键盘名称里带有 "BT"、"audio" 等片段时被误判成耳机。
        if lowercasedName.contains("keyboard") || lowercasedName.contains("键盘") || lowercasedName.contains("x75") || lowercasedName.contains("eweadn") {
            return "keyboard"
        }
        if lowercasedName.contains("mouse") || lowercasedName.contains("鼠标") {
            return "computermouse"
        }
        if lowercasedName.contains("trackpad") || lowercasedName.contains("touchpad") || lowercasedName.contains("触控板") {
            return "rectangle.and.hand.point.up.left"
        }
        if lowercasedName.contains("iphone") || lowercasedName.contains("phone") || lowercasedName.contains("手机") {
            return "iphone"
        }
        if lowercasedName.contains("ipad") || lowercasedName.contains("平板") {
            return "ipad"
        }
        let audioFragments = ["airpods", "beats", "headphone", "headphones", "headset", "earbud", "earbuds", "audio", "buds", "freebuds", "galaxy buds", "soundcore", "bose", "sony wf", "sony wh", "jabra", "marshall", "nothing ear", "耳机", "蓝牙音频"]
        if audioFragments.contains(where: { lowercasedName.contains($0) }) {
            return "headphones"
        }
        return "dot.radiowaves.left.and.right"
    }
}

struct PowerFlowSnapshot: Equatable, Sendable {
    nonisolated static let empty = PowerFlowSnapshot(
        adapterWatts: nil,
        systemWatts: nil,
        batteryWatts: nil,
        batteryPercentage: nil,
        isPluggedIn: false,
        isActivelyCharging: false
    )

    let adapterWatts: Double?
    let systemWatts: Double?
    let batteryWatts: Double?
    let batteryPercentage: Int?
    let isPluggedIn: Bool
    let isActivelyCharging: Bool

    var isDischarging: Bool {
        !isPluggedIn && batteryWatts != nil
    }
}

private struct PowerStateSignature: Equatable {
    let percent: Int?
    let state: String
    let isCharging: Bool

    nonisolated static func == (lhs: PowerStateSignature, rhs: PowerStateSignature) -> Bool {
        lhs.percent == rhs.percent && lhs.state == rhs.state && lhs.isCharging == rhs.isCharging
    }
}

struct BatterySnapshot {
    let percentage: Int?
    let isPresent: Bool
    let isCharging: Bool
    let isActivelyCharging: Bool
    let chargingPowerWatts: Int?
    let batteryOutputWatts: Int?
    let powerFlow: PowerFlowSnapshot
    let displayValue: String
    let accessories: [AccessoryBatterySnapshot]

    nonisolated var chargingPowerDisplay: String? {
        if isActivelyCharging, let chargingPowerWatts {
            return "给电池 \(chargingPowerWatts) W"
        }
        if isCharging, let chargingPowerWatts {
            return "直接供电 \(chargingPowerWatts) W"
        }
        if let batteryOutputWatts {
            return "电池输出 \(batteryOutputWatts) W"
        }
        return nil
    }

    nonisolated var powerStateDisplay: String {
        if isActivelyCharging { return "给电池供电" }
        if isCharging { return "直接供电" }
        return "电池输出"
    }
}

enum BatteryMonitor {
    nonisolated(unsafe) private static var cachedSnapshot: BatterySnapshot?
    nonisolated(unsafe) private static var cachedSnapshotTime: TimeInterval = 0
    nonisolated(unsafe) private static var cachedPowerSignature: PowerStateSignature?
    nonisolated(unsafe) private static var cachedAccessories: [AccessoryBatterySnapshot] = []
    nonisolated(unsafe) private static var cachedAccessoriesTime: TimeInterval = 0
    nonisolated(unsafe) private static var isAccessoryRefreshInFlight = false
    nonisolated private static let cacheLock = NSLock()
    nonisolated private static let accessoryRefreshQueue = DispatchQueue(label: "Chananyah.Monitor.AccessoryBatteryRefresh", qos: .utility)

    nonisolated static func snapshot() -> BatterySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if MonitorRefreshMode.current == .foreground {
            refreshAccessoryBatteriesIfNeeded(now: now)
        }
        let powerSignature = currentPowerStateSignature()

        cacheLock.lock()
        if let cachedSnapshot,
           cachedPowerSignature == powerSignature,
           now - cachedSnapshotTime < MonitorRefreshMode.current.interval {
            cacheLock.unlock()
            return cachedSnapshot
        }
        cacheLock.unlock()

        let snapshot = uncachedSnapshot(now: now)

        cacheLock.lock()
        cachedSnapshot = snapshot
        cachedSnapshotTime = now
        cachedPowerSignature = powerSignature
        cacheLock.unlock()

        return snapshot
    }

    nonisolated private static func currentPowerStateSignature() -> PowerStateSignature? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let percent = positiveInt(from: info[kIOPSCurrentCapacityKey], maxValue: 100)
            let state = info[kIOPSPowerSourceStateKey] as? String
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            return PowerStateSignature(percent: percent, state: state ?? "", isCharging: charging)
        }
        return nil
    }

    nonisolated private static func uncachedSnapshot(now: TimeInterval) -> BatterySnapshot {
        let registryAccessories = readAccessoryBatteries()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatterySnapshot(
                percentage: nil,
                isPresent: false,
                isCharging: false,
                isActivelyCharging: false,
                chargingPowerWatts: nil,
                batteryOutputWatts: nil,
                powerFlow: .empty,
                displayValue: "—",
                accessories: registryAccessories
            )
        }

        var powerSourceAccessories: [AccessoryBatterySnapshot] = []

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let isPresent = info[kIOPSIsPresentKey] as? Bool ?? true
            let isInternal = info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            guard isPresent else { continue }

            if let current = positiveInt(from: info[kIOPSCurrentCapacityKey], maxValue: 100) {
                if !isInternal {
                    let name = accessoryPowerSourceName(from: info)
                    powerSourceAccessories.append(AccessoryBatterySnapshot(
                        name: name,
                        percentage: min(max(current, 0), 100),
                        symbolNameOverride: accessorySymbolName(from: info, name: name)
                    ))
                    continue
                }

                let powerSourceState = info[kIOPSPowerSourceStateKey] as? String
                let isOnACPower = powerSourceState == kIOPSACPowerValue
                let isActivelyCharging = info[kIOPSIsChargingKey] as? Bool ?? false
                let isPluggedIn = isOnACPower || isActivelyCharging
                let adapterWatts = isPluggedIn ? readAdapterInputPowerWatts() : nil
                let batteryChargeWatts = isActivelyCharging ? readBatteryChargePowerWatts() : nil
                let systemWatts: Double? = if isPluggedIn {
                    if let adapterWatts, let batteryChargeWatts {
                        max(adapterWatts - batteryChargeWatts, 0)
                    } else {
                        adapterWatts
                    }
                } else {
                    nil
                }
                let batteryOutputWatts = isPluggedIn ? nil : readBatteryOutputPowerWatts()
                let powerFlow = PowerFlowSnapshot(
                    adapterWatts: adapterWatts,
                    systemWatts: systemWatts,
                    batteryWatts: isPluggedIn ? batteryChargeWatts : batteryOutputWatts,
                    batteryPercentage: current,
                    isPluggedIn: isPluggedIn,
                    isActivelyCharging: isActivelyCharging
                )
                return BatterySnapshot(
                    percentage: current,
                    isPresent: true,
                    isCharging: isActivelyCharging || isOnACPower,
                    isActivelyCharging: isActivelyCharging,
                    chargingPowerWatts: roundedWatts(isActivelyCharging ? batteryChargeWatts : systemWatts ?? adapterWatts),
                    batteryOutputWatts: roundedWatts(batteryOutputWatts),
                    powerFlow: powerFlow,
                    displayValue: "\(current)",
                    accessories: mergedAccessories(powerSourceAccessories, registryAccessories)
                )
            }
        }

        return BatterySnapshot(
            percentage: nil,
            isPresent: false,
            isCharging: false,
            isActivelyCharging: false,
            chargingPowerWatts: nil,
            batteryOutputWatts: nil,
            powerFlow: .empty,
            displayValue: "—",
            accessories: mergedAccessories(powerSourceAccessories, registryAccessories)
        )
    }

    nonisolated private static func accessoryPowerSourceName(from info: [String: Any]) -> String {
        let keys = [
            String(describing: kIOPSNameKey),
            String(describing: kIOPSPowerSourceIDKey),
            "Name",
            "Product",
            "DeviceName"
        ]

        for key in keys {
            if let name = info[key] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "蓝牙设备"
    }

    nonisolated private static func mergedAccessories(
        _ primary: [AccessoryBatterySnapshot],
        _ secondary: [AccessoryBatterySnapshot]
    ) -> [AccessoryBatterySnapshot] {
        var seenNames = Set<String>()
        return (primary + secondary).filter { device in
            seenNames.insert(device.name).inserted
        }
        .prefix(1)
        .map { $0 }
    }

    nonisolated private static func readAccessoryBatteries() -> [AccessoryBatterySnapshot] {
        let now = ProcessInfo.processInfo.systemUptime
        if MonitorRefreshMode.current == .foreground {
            refreshAccessoryBatteriesIfNeeded(now: now)
        }

        cacheLock.lock()
        let accessories = cachedAccessories
        cacheLock.unlock()

        return Array(accessories.prefix(1))
    }

    nonisolated private static func refreshAccessoryBatteriesIfNeeded(now: TimeInterval) {
        guard MonitorRefreshMode.current == .foreground else { return }

        cacheLock.lock()
        if now - cachedAccessoriesTime < MonitorRefreshMode.current.interval {
            cacheLock.unlock()
            return
        }
        guard !isAccessoryRefreshInFlight else {
            cacheLock.unlock()
            return
        }
        isAccessoryRefreshInFlight = true
        cacheLock.unlock()

        accessoryRefreshQueue.async {
            let accessories = performAccessoryBatteryScan()
            let finishedAt = ProcessInfo.processInfo.systemUptime

            cacheLock.lock()
            cachedAccessories = accessories
            cachedAccessoriesTime = finishedAt
            cachedSnapshot = nil
            isAccessoryRefreshInFlight = false
            cacheLock.unlock()
        }
    }

    nonisolated private static func performAccessoryBatteryScan() -> [AccessoryBatterySnapshot] {
        let connectedNames = connectedBluetoothDeviceNames()
        let devices = readAccessoryBatteriesFromHIDManager()
        + readAccessoryBatteriesFromIOBluetooth()
        + BluetoothAccessoryBatteryScanner.shared.cachedAccessories(connectedNames: connectedNames)
        + [
            "AppleBluetoothHIDKeyboard",
            "AppleBluetoothHIDMouse",
            "BNBMouseDevice",
            "BNBKeyboardDevice",
            "AppleHSBluetoothDevice",
            "IOBluetoothHIDDriver",
            "IOBluetoothDevice"
        ]
        .flatMap { readAccessoryBatteriesFromRegistry(className: $0) }
        var seenNames = Set<String>()
        let accessories = devices.filter { device in
            seenNames.insert(device.name).inserted
        }
        .prefix(1)
        .map { $0 }

        return accessories
    }

    nonisolated private static func readAccessoryBatteriesFromHIDManager() -> [AccessoryBatterySnapshot] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let hidDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        var devices: [AccessoryBatterySnapshot] = []
        var seenNames = Set<String>()
        let connectedNames = connectedBluetoothDeviceNames()

        for device in hidDevices {
            let dictionary = hidAccessoryDictionary(for: device)
            guard let name = accessoryName(from: dictionary),
                  isExternalBatteryDevice(dictionary: dictionary, name: name) || connectedNames.contains(normalizedAccessoryDeviceName(name)),
                  let percentage = batteryPercentage(from: dictionary) ?? batteryPercentageFromHIDElements(device)
            else {
                continue
            }
            guard seenNames.insert(name).inserted else { continue }
            devices.append(AccessoryBatterySnapshot(name: name, percentage: percentage, symbolNameOverride: accessorySymbolName(from: dictionary, name: name)))
        }

        return devices
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(1)
            .map { $0 }
    }

    nonisolated private static func connectedBluetoothDeviceNames() -> Set<String> {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return Set(devices.compactMap { device in
            guard device.isConnected() else { return nil }
            let name = (device.name ?? device.nameOrAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : normalizedAccessoryDeviceName(name)
        })
    }

    nonisolated fileprivate static func normalizedAccessoryDeviceName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func readAccessoryBatteriesFromIOBluetooth() -> [AccessoryBatterySnapshot] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }

        var snapshots: [AccessoryBatterySnapshot] = []
        for device in devices where device.isConnected() {
            let name = (device.name ?? device.nameOrAddress ?? "蓝牙设备")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let percentage = batteryPercentage(fromBluetoothDevice: device)
            else { continue }

            snapshots.append(AccessoryBatterySnapshot(
                name: name,
                percentage: percentage,
                symbolNameOverride: accessorySymbolName(from: bluetoothDeviceDictionary(device), name: name)
            ))
        }

        return snapshots
    }

    nonisolated private static func batteryPercentage(fromBluetoothDevice device: IOBluetoothDevice) -> Int? {
        let selectors = [
            "batteryPercent",
            "batteryPercentage",
            "batteryLevel",
            "batteryPower",
            "batteryPercentCombined",
            "batteryPercentLeft",
            "batteryPercentRight",
            "batteryPercentCase",
            "batteryLevelLeft",
            "batteryLevelRight",
            "batteryLevelCase",
            "deviceBatteryPercent",
            "deviceBatteryLevel",
            "getBatteryPercent",
            "getBatteryLevel",
            "batteryInfo",
            "batteryStatus",
            "powerSource"
        ]

        for selectorName in selectors {
            let selector = Selector(selectorName)
            guard device.responds(to: selector) else { continue }
            let value = batteryValue(from: device, selector: selector)
            if let percentage = positiveInt(from: value, maxValue: 100) {
                return percentage
            }
            if let dictionary = value as? [String: Any], let percentage = batteryPercentage(from: dictionary) {
                return percentage
            }
            if let dictionary = value as? NSDictionary, let percentage = batteryPercentage(from: dictionary as? [String: Any] ?? [:]) {
                return percentage
            }
        }
        return nil
    }

    nonisolated private static func batteryValue(from object: AnyObject, selector: Selector) -> Any? {
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        var returnType = [CChar](repeating: 0, count: 8)
        method_getReturnType(method, &returnType, returnType.count)
        let type = String(cString: returnType)

        if type == "@" {
            typealias MessageSendObject = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            let implementation = object.method(for: selector)
            let function = unsafeBitCast(implementation, to: MessageSendObject.self)
            return function(object, selector)?.takeUnretainedValue()
        }

        if ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q", "B"].contains(type) {
            return intReturnValue(from: object, selector: selector)
        }

        if ["f", "d"].contains(type) {
            return doubleReturnValue(from: object, selector: selector, type: type)
        }

        return nil
    }

    nonisolated private static func intReturnValue(from object: AnyObject, selector: Selector) -> Int? {
        typealias MessageSendInt = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: MessageSendInt.self)
        let value = Int(function(object, selector))
        return value > 0 ? value : nil
    }

    nonisolated private static func doubleReturnValue(from object: AnyObject, selector: Selector, type: String) -> Double? {
        let implementation = object.method(for: selector)
        if type == "f" {
            typealias MessageSendFloat = @convention(c) (AnyObject, Selector) -> Float
            let function = unsafeBitCast(implementation, to: MessageSendFloat.self)
            let value = Double(function(object, selector))
            return value > 0 ? value : nil
        }

        typealias MessageSendDouble = @convention(c) (AnyObject, Selector) -> Double
        let function = unsafeBitCast(implementation, to: MessageSendDouble.self)
        let value = function(object, selector)
        return value > 0 ? value : nil
    }

    nonisolated private static func bluetoothDeviceDictionary(_ device: IOBluetoothDevice) -> [String: Any] {
        var dictionary: [String: Any] = [
            "Transport": "Bluetooth",
            "Name": device.name ?? device.nameOrAddress ?? ""
        ]
        if let services = device.services as? [IOBluetoothSDPServiceRecord] {
            let serviceNames = services.compactMap { $0.getServiceName() }.joined(separator: " ")
            if !serviceNames.isEmpty {
                dictionary["BluetoothServices"] = serviceNames
            }
        }
        return dictionary
    }

    nonisolated private static func hidAccessoryDictionary(for device: IOHIDDevice) -> [String: Any] {
        let keys = [
            String(kIOHIDProductKey),
            String(kIOHIDManufacturerKey),
            String(kIOHIDTransportKey),
            String(kIOHIDPrimaryUsageKey),
            String(kIOHIDPrimaryUsagePageKey),
            "BatteryPercent",
            "BatteryPercentage",
            "BatteryLevel",
            "BatteryStrength",
            "DeviceBatteryPercent",
            "DeviceBatteryStrength",
            "AppleBluetoothHIDBatteryPercent",
            "BluetoothDevice",
            "ConnectedViaBluetooth",
            "Built-In"
        ]

        var dictionary: [String: Any] = [:]
        for key in keys {
            if let value = IOHIDDeviceGetProperty(device, key as CFString) {
                dictionary[key] = value
            }
        }
        return dictionary
    }

    nonisolated private static func batteryPercentageFromHIDElements(_ device: IOHIDDevice) -> Int? {
        let candidates: [(usagePage: Int, usage: Int)] = [
            (kHIDPage_GenericDeviceControls, kHIDUsage_GenDevControls_BatteryStrength),
            (kHIDPage_Digitizer, kHIDUsage_Dig_BatteryStrength),
            (kHIDPage_BatterySystem, kHIDUsage_BS_RelativeStateOfCharge),
            (kHIDPage_BatterySystem, kHIDUsage_BS_AbsoluteStateOfCharge)
        ].map { (Int($0.0), Int($0.1)) }

        for candidate in candidates {
            let matching: [String: Any] = [
                String(kIOHIDElementUsagePageKey): candidate.usagePage,
                String(kIOHIDElementUsageKey): candidate.usage
            ]
            guard let elements = IOHIDDeviceCopyMatchingElements(
                device,
                matching as CFDictionary,
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) as? [IOHIDElement] else {
                continue
            }

            for element in elements {
                let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
                defer { valuePointer.deallocate() }

                guard IOHIDDeviceGetValue(device, element, valuePointer) == kIOReturnSuccess else {
                    continue
                }
                let value = valuePointer.pointee.takeUnretainedValue()
                guard let percentage = positiveInt(from: IOHIDValueGetIntegerValue(value), maxValue: 100) else { continue }
                return percentage
            }
        }

        return nil
    }

    nonisolated private static func readAccessoryBatteriesFromRegistry(className: String?) -> [AccessoryBatterySnapshot] {
        guard let className else { return [] }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [AccessoryBatterySnapshot] = []
        var seenNames = Set<String>()
        let connectedNames = connectedBluetoothDeviceNames()
        var inspectedServiceCount = 0

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            inspectedServiceCount += 1
            if inspectedServiceCount > 120 {
                IOObjectRelease(service)
                break
            }
            defer { IOObjectRelease(service) }

            guard let dictionary = accessoryDictionary(for: service),
                  let percentage = batteryPercentage(from: dictionary),
                  let name = accessoryName(from: dictionary),
                  isExternalBatteryDevice(dictionary: dictionary, name: name) || connectedNames.contains(normalizedAccessoryDeviceName(name))
            else {
                continue
            }

            guard !name.isEmpty, seenNames.insert(name).inserted else { continue }

            devices.append(AccessoryBatterySnapshot(name: name, percentage: percentage, symbolNameOverride: accessorySymbolName(from: dictionary, name: name)))
        }

        return Array(devices.prefix(1))
    }

    nonisolated private static func accessoryDictionary(for service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              var dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        let linkedKeys = [
            "BatteryPercent",
            "BatteryPercentage",
            "BatteryLevel",
            "DeviceBatteryPercent",
            "AppleBluetoothHIDBatteryPercent",
            "BatteryPercentCombined",
            "BatteryPercentLeft",
            "BatteryPercentRight",
            "BatteryPercentCase",
            "Product",
            "DeviceName",
            "Name",
            "DisplayName",
            "Transport",
            "DeviceTransport",
            "BluetoothDevice",
            "ConnectedViaBluetooth"
        ]

        for key in linkedKeys where dictionary[key] == nil {
            if let value = registryLinkedValue(service: service, key: key) {
                dictionary[key] = value
            }
        }

        return dictionary
    }

    nonisolated private static func registryLinkedValue(service: io_registry_entry_t, key: String) -> Any? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            options
        )
    }

    nonisolated private static func batteryPercentage(from dictionary: [String: Any]) -> Int? {
        let keys = [
            "BatteryPercent",
            "Battery Percentage",
            "BatteryPercentage",
            "BatteryLevel",
            "Battery Level",
            "DeviceBatteryPercent",
            "DeviceBatteryStrength",
            "BatteryStrength",
            "BatteryPercentSingle",
            "BatteryPercentMain",
            "HIDBatteryPercent",
            "BatteryPercentCombined",
            "BatteryPercentCase",
            "BatteryPercentLeft",
            "BatteryPercentRight",
            "AppleBluetoothHIDBatteryPercent",
            "PowerSourceState"
        ]
        for key in keys {
            if let value = positiveInt(from: dictionary[key], maxValue: 100) {
                return value
            }
        }

        if let powerSource = dictionary["PowerSource"] as? [String: Any] {
            for key in keys {
                if let value = positiveInt(from: powerSource[key], maxValue: 100) {
                    return value
                }
            }
        }

        for (key, value) in flattened(dictionary, limit: 80) {
            guard key.count <= 160 else { continue }
            let lowered = key.lowercased()
            guard lowered.contains("battery") || lowered.contains("power"),
                  lowered.contains("percent") || lowered.contains("level") || lowered.contains("capacity")
            else { continue }
            if let value = positiveInt(from: value, maxValue: 100) {
                return value
            }
        }
        return nil
    }

    nonisolated private static func accessoryName(from dictionary: [String: Any]) -> String? {
        let keys = [
            "Product",
            "DeviceName",
            "Name",
            "DisplayName",
            String(describing: kIOPSNameKey),
            "IOUserClass"
        ]
        for key in keys {
            if let value = dictionary[key] as? String {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    nonisolated fileprivate static func accessorySymbolName(from dictionary: [String: Any], name: String) -> String? {
        let usagePage = positiveInt(from: dictionary[String(kIOHIDPrimaryUsagePageKey)])
            ?? positiveInt(from: dictionary["PrimaryUsagePage"])
        let usage = positiveInt(from: dictionary[String(kIOHIDPrimaryUsageKey)])
            ?? positiveInt(from: dictionary["PrimaryUsage"])

        if usagePage == kHIDPage_GenericDesktop {
            switch usage {
            case kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad:
                return "keyboard"
            case kHIDUsage_GD_Mouse:
                return "computermouse"
            case kHIDUsage_GD_Pointer:
                return "cursorarrow.motionlines"
            default:
                break
            }
        }

        let lowercasedName = name.lowercased()
        let descriptorText = (dictionary["BluetoothServices"] as? String ?? "")
            .appending(" ")
            .appending(dictionary.map { "\($0.key) \($0.value)" }.joined(separator: " "))
            .lowercased()

        if lowercasedName.contains("keyboard") || lowercasedName.contains("键盘") || lowercasedName.contains("x75") || lowercasedName.contains("eweadn") {
            return "keyboard"
        }
        if lowercasedName.contains("mouse") || lowercasedName.contains("鼠标") {
            return "computermouse"
        }
        if lowercasedName.contains("trackpad") || lowercasedName.contains("touchpad") || lowercasedName.contains("触控板") {
            return "rectangle.and.hand.point.up.left"
        }
        if lowercasedName.contains("iphone") || lowercasedName.contains("phone") || lowercasedName.contains("手机") || descriptorText.contains("phone") || descriptorText.contains("pbap") || descriptorText.contains("handsfree audio gateway") {
            return "iphone"
        }
        if lowercasedName.contains("ipad") || lowercasedName.contains("平板") {
            return "ipad"
        }
        let audioFragments = [
            "airpods",
            "beats",
            "headphone",
            "headphones",
            "headset",
            "earbud",
            "earbuds",
            "audio",
            "stereo",
            "a2dp",
            "buds",
            "freebuds",
            "galaxy buds",
            "soundcore",
            "bose",
            "sony wf",
            "sony wh",
            "jabra",
            "marshall",
            "nothing ear",
            "耳机",
            "蓝牙音频"
        ]
        if audioFragments.contains(where: { lowercasedName.contains($0) || descriptorText.contains($0) }) {
            return "headphones"
        }
        return nil
    }

    nonisolated private static func isExternalBatteryDevice(dictionary: [String: Any], name: String) -> Bool {
        if dictionary["Built-In"] as? Bool == true { return false }

        let loweredName = name.lowercased()
        let blockedNameFragments = [
            "apple internal",
            "internal keyboard",
            "internal trackpad",
            "pmu ",
            "tdie",
            "tdev",
            "temperature",
            "thermal"
        ]
        if blockedNameFragments.contains(where: { loweredName.contains($0) }) {
            return false
        }

        let transport = (dictionary["Transport"] as? String ?? dictionary["DeviceTransport"] as? String ?? "").lowercased()
        if transport.contains("bluetooth") { return true }

        if dictionary["BluetoothDevice"] as? Bool == true || dictionary["ConnectedViaBluetooth"] as? Bool == true {
            return true
        }
        return false
    }

    nonisolated private static func readAdapterInputPowerWatts() -> Double? {
        if let smcPower = SMCService.shared.dcInPower(), smcPower > 0 {
            return smcPower
        }

        if let watts = readSystemPowerInMilliwatts().flatMap(wattsFromMilliwattsDouble) {
            return watts
        }

        if let watts = readSystemPowerFromCurrentVoltageMilliwatts().flatMap(wattsFromMilliwattsDouble) {
            return watts
        }

        if let watts = readChargerPowerMilliwatts().flatMap(wattsFromMilliwattsDouble) {
            return watts
        }

        return nil
    }

    nonisolated private static func readBatteryChargePowerWatts() -> Double? {
        readChargerPowerMilliwatts().flatMap(wattsFromMilliwattsDouble)
    }

    nonisolated private static func readBatteryOutputPowerWatts() -> Double? {
        guard let service = matchingBatteryService() else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        let voltageMillivolts = positiveInt(from: dictionary["Voltage"])
            ?? positiveInt(from: dictionary["AppleRawBatteryVoltage"])
        guard let voltageMillivolts else { return nil }

        let amperageMilliamps = signedInt(from: dictionary["Amperage"])
            ?? signedInt(from: dictionary["InstantAmperage"])
            ?? signedInt(from: dictionary["Current"])
        guard let amperageMilliamps, amperageMilliamps != 0 else { return nil }

        let milliwatts = abs(amperageMilliamps) * voltageMillivolts / 1000
        return wattsFromMilliwattsDouble(milliwatts)
    }

    nonisolated private static func wattsFromMilliwattsDouble(_ milliwatts: Int) -> Double? {
        guard milliwatts > 0 else { return nil }
        return Double(milliwatts) / 1000
    }

    nonisolated private static func roundedWatts(_ watts: Double?) -> Int? {
        guard let watts, watts > 0 else { return nil }
        return max(Int(watts.rounded()), 1)
    }

    nonisolated private static func readSystemPowerInMilliwatts() -> Int? {
        guard let service = matchingBatteryService() else { return nil }
        defer { IOObjectRelease(service) }

        guard let telemetry = IORegistryEntryCreateCFProperty(
            service,
            "PowerTelemetryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        return positiveInt(from: telemetry["SystemPowerIn"], maxValue: 500_000)
    }

    nonisolated private static func readSystemPowerFromCurrentVoltageMilliwatts() -> Int? {
        guard let service = matchingBatteryService() else { return nil }
        defer { IOObjectRelease(service) }

        guard let telemetry = IORegistryEntryCreateCFProperty(
            service,
            "PowerTelemetryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
              let currentMilliAmps = positiveInt(from: telemetry["SystemCurrentIn"]),
              let voltageMilliVolts = positiveInt(from: telemetry["SystemVoltageIn"])
        else {
            return nil
        }

        return (currentMilliAmps * voltageMilliVolts) / 1000
    }

    nonisolated private static func readChargerPowerMilliwatts() -> Int? {
        guard let service = matchingBatteryService() else { return nil }
        defer { IOObjectRelease(service) }

        guard let chargerData = IORegistryEntryCreateCFProperty(
            service,
            "ChargerData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
              let currentMilliAmps = positiveInt(from: chargerData["ChargingCurrent"]),
              let voltageMilliVolts = positiveInt(from: chargerData["ChargingVoltage"])
        else {
            return nil
        }

        return (currentMilliAmps * voltageMilliVolts) / 1000
    }

    nonisolated private static func matchingBatteryService() -> io_registry_entry_t? {
        let matching = IOServiceMatching("AppleSmartBattery")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    nonisolated private static func positiveInt(from value: Any?, maxValue: Int = Int.max) -> Int? {
        let rawValue: Int?
        if let intValue = value as? Int {
            rawValue = intValue
        } else if let number = value as? NSNumber {
            rawValue = number.intValue
        } else if let string = value as? String {
            rawValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            rawValue = nil
        }

        guard let rawValue, rawValue > 0, rawValue <= maxValue else { return nil }
        return rawValue
    }

    nonisolated private static func signedInt(from value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private static func flattened(_ dictionary: [String: Any], prefix: String = "", limit: Int = 200) -> [String: Any] {
        var values: [String: Any] = [:]
        func walk(_ dictionary: [String: Any], prefix: String) {
            guard values.count < limit else { return }
            for (key, value) in dictionary {
                guard values.count < limit else { break }
                let nextKey = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nested = value as? [String: Any] {
                    walk(nested, prefix: nextKey)
                } else if let nested = value as? NSDictionary {
                    var converted: [String: Any] = [:]
                    for (nestedKey, nestedValue) in nested {
                        guard let nestedKey = nestedKey as? String else { continue }
                        converted[nestedKey] = nestedValue
                    }
                    walk(converted, prefix: nextKey)
                } else {
                    values[nextKey] = value
                }
            }
        }

        walk(dictionary, prefix: prefix)
        return values
    }
}

final class BatteryPowerSourceObserver {
    private var runLoopSource: CFRunLoopSource?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<BatteryPowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            observer.onChange?()
        }, context) else {
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.runLoopSource = nil
        onChange = nil
    }

    deinit {
        stop()
    }
}

private final class BluetoothAccessoryBatteryScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    nonisolated static let shared = BluetoothAccessoryBatteryScanner()

    private let queue = DispatchQueue(label: "Chananyah.Monitor.BluetoothAccessoryBattery", qos: .utility)
    private let lock = NSLock()
    private let scanDuration: TimeInterval = 5
    nonisolated private static let batteryServiceUUID = CBUUID(string: "180F")
    nonisolated private static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    nonisolated private static let hidServiceUUID = CBUUID(string: "1812")

    nonisolated(unsafe) private var central: CBCentralManager?
    nonisolated(unsafe) private var cached: [AccessoryBatterySnapshot] = []
    nonisolated(unsafe) private var lastRefreshStartedAt: TimeInterval = 0
    nonisolated(unsafe) private var isScanning = false
    nonisolated(unsafe) private var discovered: [String: AccessoryBatterySnapshot] = [:]
    nonisolated(unsafe) private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    nonisolated(unsafe) private var allowedConnectedNames: Set<String> = []

    nonisolated func cachedAccessories(connectedNames: Set<String>) -> [AccessoryBatterySnapshot] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        allowedConnectedNames = connectedNames
        let current = cached.filter { connectedNames.contains(BatteryMonitor.normalizedAccessoryDeviceName($0.name)) }
        let shouldRefresh = MonitorRefreshMode.current == .foreground
            && !connectedNames.isEmpty
            && !isScanning
            && now - lastRefreshStartedAt >= MonitorRefreshMode.current.interval
        if shouldRefresh {
            lastRefreshStartedAt = now
            isScanning = true
        }
        lock.unlock()

        if shouldRefresh {
            queue.async { [weak self] in
                self?.startScanOnQueue()
            }
        }

        return current
    }

    nonisolated private func startScanOnQueue() {
        guard MonitorRefreshMode.current == .foreground else {
            finishScan()
            return
        }

        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            return
        }

        guard let central, central.state == .poweredOn else {
            finishScan()
            return
        }

        discovered.removeAll()
        readConnectedBatteryServicePeripherals()
        central.scanForPeripherals(
            withServices: [Self.batteryServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        queue.asyncAfter(deadline: .now() + scanDuration) { [weak self] in
            self?.finishScan()
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard MonitorRefreshMode.current == .foreground else {
            finishScan()
            return
        }
        guard central.state == .poweredOn else {
            finishScan()
            return
        }
        startScanOnQueue()
    }

    nonisolated private func readConnectedBatteryServicePeripherals() {
        guard let central else { return }
        let peripherals = central.retrieveConnectedPeripherals(withServices: [Self.batteryServiceUUID, Self.hidServiceUUID])
        for peripheral in peripherals {
            connectedPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard MonitorRefreshMode.current == .foreground else { return }

        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let normalizedName = BatteryMonitor.normalizedAccessoryDeviceName(advertisedName)
        guard !normalizedName.isEmpty, allowedConnectedNames.contains(normalizedName) else { return }

        connectedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {

        peripheral.delegate = self
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == Self.batteryServiceUUID {
            peripheral.discoverCharacteristics([Self.batteryLevelCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, service.uuid == Self.batteryServiceUUID, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == Self.batteryLevelCharacteristicUUID {
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.batteryLevelCharacteristicUUID,
              let data = characteristic.value,
              let firstByte = data.first
        else { return }

        let percentage = min(max(Int(firstByte), 0), 100)
        guard percentage > 0 else { return }

        let name = matchingConnectedName(for: peripheral)
            ?? (peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "蓝牙设备"
        guard allowedConnectedNames.contains(BatteryMonitor.normalizedAccessoryDeviceName(name)) else { return }
        discovered[name] = AccessoryBatterySnapshot(name: name, percentage: percentage, symbolNameOverride: BatteryMonitor.accessorySymbolName(from: ["Transport": "Bluetooth"], name: name))
    }

    nonisolated private func matchingConnectedName(for peripheral: CBPeripheral) -> String? {
        let peripheralName = BatteryMonitor.normalizedAccessoryDeviceName(peripheral.name ?? "")
        if !peripheralName.isEmpty, allowedConnectedNames.contains(peripheralName) {
            return peripheral.name
        }
        guard allowedConnectedNames.count == 1 else { return nil }
        return allowedConnectedNames.first
    }

    nonisolated private func finishScan() {

        central?.stopScan()
        connectedPeripherals.values.forEach { central?.cancelPeripheralConnection($0) }
        connectedPeripherals.removeAll()

        lock.lock()
        cached = Array(discovered.values)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(1)
            .map { $0 }
        isScanning = false
        lock.unlock()
    }

    nonisolated private static func snapshots(fromAppleManufacturerData data: Data, localName: String) -> [AccessoryBatterySnapshot] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x4c, bytes[1] == 0x00 else { return [] }

        let normalizedName = normalizedAccessoryName(localName: localName, bytes: bytes)
        guard isLikelyAppleAudioAccessory(name: normalizedName, bytes: bytes) else { return [] }
        guard let percentage = airPodsBatteryPercentage(from: bytes) else { return [] }

        return [AccessoryBatterySnapshot(name: normalizedName, percentage: percentage)]
    }

    nonisolated private static func normalizedAccessoryName(localName: String, bytes: [UInt8]) -> String {
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if bytes.contains(0x07) { return "AirPods" }
        return "蓝牙设备"
    }

    nonisolated private static func isLikelyAppleAudioAccessory(name: String, bytes: [UInt8]) -> Bool {
        let lowercased = name.lowercased()
        if lowercased.contains("airpods") || lowercased.contains("beats") || lowercased.contains("headphone") || lowercased.contains("耳机") {
            return true
        }
        return bytes.dropFirst(2).prefix(4).contains(0x07)
    }

    nonisolated private static func airPodsBatteryPercentage(from bytes: [UInt8]) -> Int? {
        var bestComponents: [Int] = []

        for index in 2..<max(bytes.count - 1, 2) {
            let first = batteryNibbleValues(from: bytes[index])
            let second = batteryNibbleValues(from: bytes[index + 1])
            let components = [first.high, first.low, second.high].compactMap { $0 }

            guard components.count >= 2 else { continue }
            guard components.allSatisfy({ (1...10).contains($0) }) else { continue }

            if components.count > bestComponents.count {
                bestComponents = components
            }
        }

        guard !bestComponents.isEmpty else { return nil }
        let averageLevel = Double(bestComponents.reduce(0, +)) / Double(bestComponents.count)
        return min(max(Int((averageLevel * 10).rounded()), 1), 100)
    }

    nonisolated private static func batteryNibbleValues(from byte: UInt8) -> (high: Int?, low: Int?) {
        let high = Int((byte & 0xf0) >> 4)
        let low = Int(byte & 0x0f)
        return (
            high <= 10 ? high : nil,
            low <= 10 ? low : nil
        )
    }
}

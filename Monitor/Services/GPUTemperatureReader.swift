import Foundation
import IOKit

/// 独立 GPU 温度读取器。
/// 这样无需修改原仓库的 SMCService.swift，也可以在覆盖 ContentView 后直接编译。
final class GPUTemperatureReader: @unchecked Sendable {
    nonisolated static let shared = GPUTemperatureReader()

    private let lock = NSLock()
    nonisolated(unsafe) private var connection: io_connect_t = 0
    private let kernelIndex: UInt32 = 2

    private let gpuTemperatureKeys = [
        // Intel / AMD dGPU 常见 SMC key
        "TG0D", "TG0P", "TG0H", "TG0T", "TG0M", "TG0F",
        // Apple Silicon / AGX 常见候选 key，不同机型暴露情况不同
        "Tg0D", "Tg0P", "Tg0H", "Tg0T", "Tg0G", "Tg1G",
        "Tg05", "Tg15", "Tp0P", "Tp0G", "Tp1G",
        "Ts0P", "Ts0S", "Ts1P", "Ts1S", "Ta0P", "Ta1P",
        "Te05", "Te0G", "Te1G"
    ]
    nonisolated(unsafe) private var validGPUTemperatureKey: String?

    private init() {
        openConnection()
    }

    deinit {
        closeConnection()
    }

    nonisolated func gpuTemperatureCelsius() -> Double? {
        if let key = validGPUTemperatureKey,
           let value = readNumericValue(forKey: key),
           value > 0,
           value < 150 {
            return value
        }

        for key in gpuTemperatureKeys {
            if let value = readNumericValue(forKey: key), value > 0, value < 150 {
                validGPUTemperatureKey = key
                return value
            }
        }
        return nil
    }

    nonisolated private func openConnection() {
        lock.lock()
        defer { lock.unlock() }

        guard connection == 0 else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == KERN_SUCCESS else { return }
        connection = openedConnection
    }

    nonisolated private func closeConnection() {
        lock.lock()
        defer { lock.unlock() }

        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    nonisolated private func readNumericValue(forKey key: String) -> Double? {
        guard let value = readValue(forKey: key) else { return nil }
        return parseNumericValue(bytes: value.bytes, dataType: value.dataType)
    }

    nonisolated private func readValue(forKey key: String) -> SMCGPUReadResult? {
        lock.lock()
        defer { lock.unlock() }

        guard connection != 0, let encodedKey = encodeSMCKey(key) else { return nil }

        var input = SMCGPUKeyData()
        var output = SMCGPUKeyData()

        input.key = encodedKey
        input.data8 = SMCGPUCommand.readKeyInfo.rawValue
        guard callSMC(input: &input, output: &output) else { return nil }

        let keyInfo = output.keyInfo
        guard keyInfo.dataSize > 0, keyInfo.dataSize <= 32 else { return nil }

        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMCGPUCommand.readBytes.rawValue
        guard callSMC(input: &input, output: &output) else { return nil }

        let count = Int(keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: output.bytesArray) { rawBuffer in
            Array(rawBuffer.prefix(count))
        }
        return SMCGPUReadResult(
            dataType: decodeSMCType(keyInfo.dataType),
            bytes: bytes
        )
    }

    nonisolated private func callSMC(input: inout SMCGPUKeyData, output: inout SMCGPUKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCGPUKeyData>.stride
        var outputSize = MemoryLayout<SMCGPUKeyData>.stride
        return IOConnectCallStructMethod(connection, kernelIndex, &input, inputSize, &output, &outputSize) == KERN_SUCCESS
    }

    nonisolated private func parseNumericValue(bytes: [UInt8], dataType: String) -> Double? {
        guard !bytes.isEmpty else { return nil }

        switch dataType {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var value: Float = 0
            var bytesCopy = Array(bytes.prefix(4))
            memcpy(&value, &bytesCopy, 4)
            return value.isFinite ? Double(value) : nil
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw)
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(raw)
        case "si8 ":
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw))
        default:
            if bytes.count >= 2 {
                let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
                let temp = Double(raw) / 256.0
                if temp > 0, temp < 150 { return temp }
            }
            return nil
        }
    }

    nonisolated private func encodeSMCKey(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    nonisolated private func decodeSMCType(_ raw: UInt32) -> String {
        let chars = [
            Character(UnicodeScalar((raw >> 24) & 0xFF) ?? " "),
            Character(UnicodeScalar((raw >> 16) & 0xFF) ?? " "),
            Character(UnicodeScalar((raw >> 8) & 0xFF) ?? " "),
            Character(UnicodeScalar(raw & 0xFF) ?? " ")
        ]
        return String(chars)
    }
}

private enum SMCGPUCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCGPUReadResult {
    let dataType: String
    let bytes: [UInt8]
}

private struct SMCGPUKeyDataVers: Sendable {
    nonisolated init() {}
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCGPUKeyDataPLimitData: Sendable {
    nonisolated init() {}
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCGPUKeyDataKeyInfo: Sendable {
    nonisolated init() {}
    var dataSize: IOByteCount32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCGPUKeyData: Sendable {
    nonisolated init() {}
    var key: UInt32 = 0
    var vers: SMCGPUKeyDataVers = SMCGPUKeyDataVers()
    var pLimitData: SMCGPUKeyDataPLimitData = SMCGPUKeyDataPLimitData()
    var keyInfo: SMCGPUKeyDataKeyInfo = SMCGPUKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytesArray: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private extension SMCGPUKeyData {
    var bytesArrayList: [UInt8] {
        Mirror(reflecting: bytesArray).children.compactMap { $0.value as? UInt8 }
    }
}

private extension Array where Element == UInt8 {
    init(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
        self = Mirror(reflecting: tuple).children.compactMap { $0.value as? UInt8 }
    }
}

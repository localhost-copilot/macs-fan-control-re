import Foundation
import IOKit

/// All operations on a connection must be serialized by its owner.
public final class AppleSMC {
    private var connection: io_connect_t = 0
    private var metadata: [String: (Int, String)] = [:]
    private var exchange: (([UInt8]) throws -> [UInt8])?
    private var waitForMode: () -> Void = { usleep(100_000) }
    private var controlledFans = Set<Int>()
    private var ownsUnlock = false

    // Exercise the real wire decoding and control sequence without opening hardware.
    init(exchange: @escaping ([UInt8]) throws -> [UInt8], waitForMode: @escaping () -> Void = {}) {
        self.exchange = exchange
        self.waitForMode = waitForMode
    }

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanError.message("AppleSMC is not available on this computer.") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw FanError.message("Cannot open AppleSMC (\(result)).") }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    // Explicit wire offsets avoid Swift Array storage/padding in the 80-byte kernel ABI.
    private func call(key: String = "    ", command: UInt8, size: Int = 0, index: UInt32 = 0, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, size >= 0, size <= 32, bytes.count <= 32 else {
            throw FanError.message("Invalid SMC request.")
        }
        var input = [UInt8](repeating: 0, count: 80)
        var output = input
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { input[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, at: 0)
        put(UInt32(size), at: 28)
        input[42] = command
        put(index, at: 44)
        for (i, byte) in bytes.enumerated() { input[48 + i] = byte }
        var outputSize = 80
        let result: kern_return_t
        if let exchange {
            output = try exchange(input)
            outputSize = output.count
            result = KERN_SUCCESS
        } else {
            result = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
                }
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80 else {
            throw FanError.message("SMC \(key) failed (kernel \(result), response size \(outputSize)).")
        }
        guard output[40] == 0 else { throw DeviceError(key: key, status: output[40]) }
        return output
    }

    private struct DeviceError: LocalizedError {
        let key: String
        let status: UInt8
        var errorDescription: String? { "SMC \(key) failed (device \(status))." }
    }

    public func info(_ key: String) throws -> (size: Int, type: String) {
        if let cached = metadata[key] { return cached }
        let result = try call(key: key, command: 9)
        let size = Int(Self.uint32(result, at: 28))
        guard (1...32).contains(size) else { throw FanError.message("Unsupported SMC data size for \(key).") }
        let type = String(bytes: result[32..<36].reversed(), encoding: .ascii) ?? ""
        metadata[key] = (size, type)
        return (size, type)
    }
    public func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let meta = try info(key)
        let result = try call(key: key, command: 5, size: meta.size)
        return (meta.type, Array(result[48..<(48 + meta.size)]))
    }
    public func number(_ key: String) throws -> Double {
        let value = try read(key)
        return try Self.decode(type: value.type, bytes: value.bytes)
    }
    public static func decode(type: String, bytes: [UInt8]) throws -> Double {
        let characters = Array(type)
        if bytes.count == 2, characters.count == 4,
           type.hasPrefix("fp") || type.hasPrefix("sp"),
           let integral = Int(String(characters[2]), radix: 16),
           let fractional = Int(String(characters[3]), radix: 16),
           integral + fractional == (type.hasPrefix("sp") ? 15 : 16) {
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let value = type.hasPrefix("sp") ? Double(Int16(bitPattern: bits)) : Double(bits)
            return value / pow(2, Double(fractional))
        }
        switch (type, bytes.count) {
        case ("flt ", 4): return Double(Float(bitPattern: uint32(bytes, at: 0)))
        case ("fpe2", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("flag", 1), ("ui8 ", 1), ("ui16", 2), ("ui32", 4):
            return Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: throw FanError.message("Unsupported SMC type ‘\(type)’.")
        }
    }
    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    /// SMC keys for fan `n` use one uppercase hex digit: F0Ac … FFAc.
    static func fanKey(_ fan: Int, _ suffix: String) -> String { "F\(String(fan, radix: 16).uppercased())\(suffix)" }
    /// Encodings that carry a physical measurement, as opposed to flags or counters.
    static func isMeasurement(type: String) -> Bool { type == "flt " || type.hasPrefix("fp") || type.hasPrefix("sp") }
    public func keys() throws -> [String] {
        let count = try number("#KEY")
        guard count.isFinite, count > 0, count <= 65536 else { throw FanError.message("Invalid SMC key count.") }
        return (0..<Int(count)).compactMap { index in
            guard let value = try? call(command: 8, index: UInt32(index)) else { return nil }
            return String(bytes: value[0..<4].reversed(), encoding: .ascii)
        }
    }
    public func fans() throws -> [Fan] {
        let count = try number("FNum")
        guard count.isFinite, count >= 0, count <= 16 else { throw FanError.message("Invalid fan count.") }
        return try (0..<Int(count)).map { id in
            let values = try ["Mn", "Ac", "Mx"].map { try number(Self.fanKey(id, $0)) }
            guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 30000 }) else {
                throw FanError.message("Invalid fan speed returned by SMC.")
            }
            let manual: Bool
            let modeKey: String?
            if let mode = try? number(Self.fanKey(id, "md")) { manual = mode == 1; modeKey = Self.fanKey(id, "md") }
            else if let mode = try? number(Self.fanKey(id, "Md")) { manual = mode == 1; modeKey = Self.fanKey(id, "Md") }
            else if let mode = try? number("FS! "), mode.isFinite, mode >= 0, mode <= 65535 {
                manual = (Int(mode) & (1 << id)) != 0; modeKey = "FS! "
            } else { manual = false; modeKey = nil }
            var fan = Fan(id: id, name: "Fan \(id)", minimum: Int(values[0]), current: Int(values[1]), maximum: Int(values[2]), manual: manual)
            fan.modeKey = modeKey
            if let target = try? number(Self.fanKey(id, "Tg")), target.isFinite, (0...30000).contains(target) { fan.target = Int(target) }
            return fan
        }
    }
    public func temperature(_ key: String) throws -> Double {
        let value = try number(key)
        guard value.isFinite, value > 0, value < 127 else { throw FanError.message("Sensor \(key) has no valid temperature.") }
        return value
    }
    public func write(_ key: String, bytes: [UInt8]) throws {
        guard try info(key).size == bytes.count else { throw FanError.message("SMC write size mismatch.") }
        _ = try call(key: key, command: 6, size: bytes.count, bytes: bytes)
    }
    public func setAutomatic(fan: Int) throws {
        try setManual(false, fan: fan)
        // Ftst is global: retain it until the last fan owned by this connection
        // is released. Keep ownership on failure so ControlSession can retry.
        if ownsUnlock && controlledFans.subtracting([fan]).isEmpty {
            try write("Ftst", bytes: [0])
            guard try number("Ftst") == 0 else { throw FanError.message("Could not release the SMC fan-control unlock.") }
            ownsUnlock = false
        }
        controlledFans.remove(fan)
    }
    private func setManual(_ manual: Bool, fan: Int) throws {
        guard (0..<16).contains(fan) else { throw FanError.message("Invalid fan index.") }
        // Probe capabilities, not chip names. Never switch mode keys after a failure.
        if let key = [Self.fanKey(fan, "md"), Self.fanKey(fan, "Md")].first(where: { (try? info($0)) != nil }) {
            let desired: UInt8 = manual ? 1 : 0
            let current = try number(key)
            if current == Double(desired) || (!manual && current == 3) { return }
            do {
                try write(key, bytes: [desired])
            } catch let error as DeviceError where manual && error.status == 0x82 {
                try acquireUnlock()
                // thermalmonitord yields asynchronously. Bound retries and only
                // retry its specific refusal, never transport/permission errors.
                for attempt in 0..<20 {
                    waitForMode()
                    do {
                        try write(key, bytes: [desired])
                        if try number(key) == Double(desired) { return }
                    } catch let retry as DeviceError where retry.status == 0x82 {
                        if attempt == 19 { throw retry }
                    }
                }
            }
            guard try number(key) == Double(desired) else {
                throw FanError.message("SMC did not accept the requested mode for fan \(fan).")
            }
        } else {
            let value = try number("FS! ")
            guard value.isFinite, value >= 0, value <= 65535 else { throw FanError.message("Invalid legacy fan mode bitfield.") }
            let old = UInt16(value)
            let mask = manual ? old | (1 << fan) : old & ~(1 << fan)
            try write("FS! ", bytes: [UInt8(mask >> 8), UInt8(mask & 255)])
            guard try number("FS! ") == Double(mask) else {
                throw FanError.message("SMC did not accept the legacy fan mode bitfield.")
            }
        }
    }

    private func acquireUnlock() throws {
        let flag = try read("Ftst")
        guard ["ui8 ", "flag"].contains(flag.type), flag.bytes.count == 1, flag.bytes[0] <= 1 else {
            throw FanError.message("Unsupported SMC fan-control unlock encoding.")
        }
        guard flag.bytes[0] == 0 else { return }
        guard try fans().allSatisfy({ !$0.manual || controlledFans.contains($0.id) }) else {
            throw FanError.message("Another fan is under manual control. Release it before acquiring the global SMC unlock.")
        }
        ownsUnlock = true
        try write("Ftst", bytes: [1])
    }
    public func setRPM(_ rpm: Int, fan: Fan) throws {
        try ControlMode.constant(rpm).validate(for: fan)
        let key = Self.fanKey(fan.id, "Tg")
        let type = try info(key).type
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let value = Float(rpm).bitPattern
            bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        case "fpe2":
            guard rpm <= 16383 else { throw FanError.message("RPM exceeds the SMC encoding range.") }
            bytes = [UInt8((rpm * 4) >> 8), UInt8((rpm * 4) & 255)]
        default: throw FanError.message("Unsupported fan target encoding: \(type).")
        }
        controlledFans.insert(fan.id)
        do {
            try setManual(true, fan: fan.id)
            try write(key, bytes: bytes)
            guard try number(key) == Double(rpm) else { throw FanError.message("SMC did not accept the requested fan speed.") }
        } catch {
            let original = error
            do { try setAutomatic(fan: fan.id) }
            catch { throw FanError.message("\(original.localizedDescription) Automatic recovery also failed: \(error.localizedDescription)") }
            throw original
        }
    }
}

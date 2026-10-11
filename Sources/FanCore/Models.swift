import Foundation

public struct Fan: Identifiable, Codable, Equatable {
    public let id: Int
    public var name: String
    public var minimum: Int
    public var current: Int
    public var maximum: Int
    public var manual: Bool
    public var target: Int?
    public var modeKey: String?
    public init(id: Int, name: String, minimum: Int, current: Int, maximum: Int, manual: Bool = false) {
        self.id = id; self.name = name; self.minimum = minimum; self.current = current
        self.maximum = maximum; self.manual = manual
    }
}

public enum SensorQuantity: String, Codable, CaseIterable {
    case temperature, voltage, current, power
    public var symbol: String {
        switch self { case .temperature: return "°C"; case .voltage: return "V"; case .current: return "A"; case .power: return "W" }
    }
}

public struct Sensor: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var value: Double?
    public var quantity: SensorQuantity
    public var source: String
    public var issue: String?
    public var backingSMCKey: String?
    public var rawValue: Double?
    // Electrical channels can never become temperature control inputs.
    public var celsius: Double? { quantity == .temperature ? value : nil }
    public var category: String
    public var isVisibleByDefault: Bool
    public init(id: String, name: String, celsius: Double?, category: String = "temperature", isVisibleByDefault: Bool = true) {
        self.id = id; self.name = name; self.value = celsius; self.category = category
        quantity = .temperature; source = id.hasPrefix("avg:") || id.hasPrefix("max:") ? "Calculated" : "SMC"
        self.isVisibleByDefault = isVisibleByDefault
    }
    public init(id: String, name: String, value: Double?, quantity: SensorQuantity, source: String, issue: String? = nil, category: String = "temperature") {
        self.id = id; self.name = name; self.value = value; self.quantity = quantity
        self.source = source; self.issue = issue; self.category = category; isVisibleByDefault = true
    }
}

public enum ControlMode: Codable, Equatable {
    case automatic
    case constant(Int)
    case sensor(key: String, start: Double, maximum: Double)

    public func validate(for fan: Fan) throws {
        guard fan.id >= 0, fan.id < 16 else { throw FanError.message("Invalid fan index.") }
        switch self {
        case .automatic: return
        case .constant(let rpm):
            guard fan.maximum > fan.minimum, rpm >= fan.minimum, rpm <= fan.maximum else {
                throw FanError.message("RPM must be within the fan’s hardware limits.")
            }
        case .sensor(let key, let start, let maximum):
            let validKey = (key.utf8.count == 4 && key.hasPrefix("T")) || ((key.hasPrefix("hid:") || key.hasPrefix("avg:")) && key.utf8.count > 4 && key.utf8.count < 200) || MaximumTemperature(rawValue: key) != nil
            guard validKey, start.isFinite, maximum.isFinite,
                  start >= 0, maximum <= 110, maximum - start >= 1, fan.maximum > fan.minimum else {
                throw FanError.message("Select a temperature sensor and temperatures at least 1°C apart (0–110°C).")
            }
        }
    }
}

public struct Preset: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var modes: [Int: ControlMode]
    public init(id: UUID = UUID(), name: String, modes: [Int: ControlMode]) {
        self.id = id; self.name = name; self.modes = modes
    }
}

public enum FanError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum TemperatureUnit: String, CaseIterable, Codable {
    case celsius, fahrenheit
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public func display(_ value: Double) -> Double { self == .celsius ? value : value * 1.8 + 32 }
    public func celsius(_ value: Double) -> Double { self == .celsius ? value : (value - 32) / 1.8 }
}

public enum Hardware {
    public static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
    /// True for Apple Silicon hosts even when this process runs under Rosetta.
    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

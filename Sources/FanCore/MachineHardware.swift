import Foundation

/// Shared sensor identities and validation for the GUI and privileged controller.
public final class MachineHardware: FanHardware {
    private let smc: AppleSMC
    private let hid = HIDSensorReader()
    private let power = PowerReader()
    private let catalog = SensorCatalog()
    private var keys: [String] = []
    private var cache: [String: Sensor] = [:]
    private var curated = true
    public init(ledger: URL? = nil) throws { smc = try AppleSMC(ledger: ledger) }
    public var recoveredFans: Set<Int> { smc.recoveredFans }
    public func fans() throws -> [Fan] {
        try smc.fans().map { fan in
            var result = fan; result.name = catalog.fanNames[fan.id] ?? fan.name; return result
        }
    }
    // The SMC key table is fixed for the life of the connection; enumerating
    // it costs thousands of kernel calls, so do it once.
    private func discover() throws {
        guard keys.isEmpty else { return }
        keys = try smc.keys().filter { Self.quantity($0) != nil }.sorted()
        catalog.addDiscoveredSensors(keys)
    }
    /// `full: false` re-reads only named channels and group members; other raw
    /// channels keep their last reading until the next full pass.
    public func sensors(full: Bool = true) throws -> [Sensor] {
        try discover()
        let full = full || !curated
        let members = Set(catalog.groups.values.joined())
        func visible(_ id: String) -> Bool { catalog.sensors[id] != nil && !catalog.hiddenGroupMembers.contains(id) }
        var readings = keys.map { key -> Sensor in
            let info = catalog.sensors[key]
            if !full, info == nil, !members.contains(key), let cached = cache[key] { return cached }
            let quantity = Self.quantity(key)!
            var value: Double?
            var issue: String?
            do {
                let metadata = try smc.info(key)
                guard AppleSMC.isMeasurement(type: metadata.type) else {
                    throw FanError.message("Raw SMC channel with unsupported measurement encoding: \(metadata.type).")
                }
                let raw = try quantity == .temperature ? smc.temperature(key) : smc.number(key)
                guard raw.isFinite else { throw FanError.message("SMC returned a non-finite value.") }
                value = raw
            } catch { issue = error.localizedDescription }
            var sensor = Sensor(id: key, name: info?.name ?? "\(quantity.rawValue.capitalized) \(key)", value: value, quantity: quantity, source: "SMC", issue: issue, category: info?.category ?? quantity.rawValue)
            sensor.isVisibleByDefault = visible(key)
            cache[key] = sensor
            return sensor
        }
        readings += (hid?.readings(refresh: { full || self.catalog.sensors["hid:" + $0] != nil }) ?? []).map { sensor in
            var item = sensor
            if let info = catalog.sensors[sensor.id] { item.name = info.name; item.category = info.category }
            item.isVisibleByDefault = visible(sensor.id)
            if sensor.quantity != .temperature, let key = sensor.backingSMCKey {
                if !full, !item.isVisibleByDefault, let cached = cache[sensor.id] { return cached }
                if let metadata = try? smc.info(key),
                   AppleSMC.isMeasurement(type: metadata.type),
                   let value = try? smc.number(key), value.isFinite {
                    // Some PMU HID drivers expose the bits of an SMC float as fixed
                    // point. Read the confirmed backing key instead of guessing units.
                    item.value = value; item.source = "HID/SMC"; item.issue = nil
                }
                cache[sensor.id] = item
            }
            return item
        }
        let values = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (name, members) in catalog.groups {
            let available = Set(members).compactMap { values[$0]?.celsius }
            guard !available.isEmpty else { continue }
            readings.append(Sensor(id: "avg:" + name, name: name, celsius: available.reduce(0, +) / Double(available.count), category: members.compactMap { values[$0]?.category }.first ?? "temperature"))
        }
        readings += MaximumTemperature.allCases.compactMap { $0.sensor(from: readings) }
        readings += (power?.readings() ?? []).map { sensor in
            var item = sensor; item.isVisibleByDefault = false; return item
        }
        // Models without a sensor database still get a useful default list.
        curated = readings.contains { $0.isVisibleByDefault && $0.quantity == .temperature && $0.source != "Calculated" }
        if !curated {
            for index in readings.indices where readings[index].celsius != nil { readings[index].isVisibleByDefault = true }
        }
        return readings.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    private static func quantity(_ key: String) -> SensorQuantity? {
        switch key.first { case "T": return .temperature; case "V": return .voltage; case "I": return .current; case "P": return .power; default: return nil }
    }
    public func temperature(_ key: String) throws -> Double {
        // The helper evaluates this every tick, so read only what the key needs.
        let maximum = MaximumTemperature(rawValue: key)
        if key.hasPrefix("hid:") || key.hasPrefix("avg:") || maximum != nil {
            try discover()
            let members: Set<String>
            if let maximum {
                members = Set(catalog.sensors.filter { $0.value.category == maximum.category }.map(\.key))
            } else {
                members = key.hasPrefix("avg:") ? Set(catalog.groups[String(key.dropFirst(4))] ?? []) : [key]
            }
            let hidValues = members.contains { $0.hasPrefix("hid:") }
                ? Dictionary((hid?.readings(refresh: { members.contains("hid:" + $0) }) ?? []).map { ($0.id, $0.celsius) }, uniquingKeysWith: { first, _ in first }) : [:]
            let values = members.compactMap { $0.hasPrefix("hid:") ? hidValues[$0] ?? nil : try? smc.temperature($0) }
            if maximum != nil {
                guard let value = MaximumTemperature.value(values) else {
                    throw FanError.message("No temperature readings are available in the selected CPU/GPU group.")
                }
                return value
            }
            guard !values.isEmpty else { throw FanError.message("Selected temperature sensor is unavailable or ambiguous. Select it again.") }
            return values.reduce(0, +) / Double(values.count)
        }
        guard key.utf8.count == 4, key.hasPrefix("T") else { throw FanError.message("Fan control requires a temperature channel.") }
        return try smc.temperature(key)
    }
    public func setRPM(_ rpm: Int, fan: Fan) throws { try smc.setRPM(rpm, fan: fan) }
    public func setAutomatic(fan: Int) throws { try smc.setAutomatic(fan: fan) }
}

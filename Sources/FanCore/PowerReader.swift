import Foundation

/// First samples, counter resets and sleep gaps establish a baseline, not zero W.
struct EnergyDelta {
    private var previous: (energy: Int64, time: TimeInterval, unit: String)?
    mutating func watts(energy: Int64, unit: String, now: TimeInterval) -> Double? {
        let old = previous
        previous = (energy, now, unit)
        let scale: Double
        switch unit {
        case "J": scale = 1
        case "mJ": scale = 1e-3
        case "uJ", "µJ", "μJ": scale = 1e-6
        case "nJ": scale = 1e-9
        default: return nil
        }
        guard let old, old.unit == unit, energy >= old.energy, old.energy >= 0,
              now.isFinite, now > old.time, now - old.time <= 10 else { return nil }
        return Double(energy - old.energy) * scale / (now - old.time)
    }
}

public final class PowerReader {
    private typealias Channels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Label = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64
    private static let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private let sample: Sample
    private let name: Label
    private let subgroup: Label
    private let unit: Label
    private let integer: Integer
    private var deltas: [String: EnergyDelta] = [:]
    private var lastSensors: [Sensor] = []

    public init?() {
        guard let library = Self.library else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", as: Channels.self),
              let subscribe = symbol("IOReportCreateSubscription", as: Subscribe.self),
              let sample = symbol("IOReportCreateSamples", as: Sample.self),
              let name = symbol("IOReportChannelGetChannelName", as: Label.self),
              let subgroup = symbol("IOReportChannelGetSubGroup", as: Label.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: Label.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", as: Integer.self),
              let raw = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(nil, 0, raw) else { return nil }
        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, channels, &subscribedChannels, 0, nil)?.takeRetainedValue() else {
            subscribedChannels?.release(); return nil
        }
        self.channels = subscribedChannels?.takeRetainedValue() ?? channels
        self.subscription = subscription; self.sample = sample; self.name = name
        self.subgroup = subgroup; self.unit = unit; self.integer = integer
    }

    public func readings() -> [Sensor] {
        guard let report = sample(subscription, channels, nil)?.takeRetainedValue(),
              let items = (report as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            deltas = [:]
            return lastSensors.map { sensor in
                var item = sensor; item.value = nil; item.issue = "IOReport sampling failed."; return item
            }
        }
        let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        var occurrences: [String: Int] = [:]
        var result: [Sensor] = []
        for item in items {
            let channel = item as CFDictionary
            let name = self.name(channel)?.takeUnretainedValue() as String? ?? "Unnamed energy channel"
            let group = subgroup(channel)?.takeUnretainedValue() as String? ?? ""
            let unit = self.unit(channel)?.takeUnretainedValue() as String? ?? "unknown"
            let base = "ioreport:\(group):\(name)"
            let occurrence = occurrences[base, default: 0]; occurrences[base] = occurrence + 1
            let id = base + ":\(occurrence)"
            let value = deltas[id, default: EnergyDelta()].watts(energy: integer(channel, 0), unit: unit, now: now)
            var sensor = Sensor(id: id, name: name.replacingOccurrences(of: "Energy", with: "Power"), value: value, quantity: .power, source: "IOReport", issue: value == nil ? "Waiting for two valid energy samples; source unit: \(unit)." : nil, category: "psu")
            // Only expose explicitly named processor channels by default; raw
            // rails and overlapping energy counters have no confirmed CPU/GPU mapping.
            sensor.isVisibleByDefault = name == "CPU Energy" || name == "GPU Energy"
            result.append(sensor)
        }
        let active = Set(result.map(\.id))
        deltas = deltas.filter { active.contains($0.key) }
        lastSensors = result
        return result
    }
}

import Foundation

/// The hottest currently readable CPU/GPU channel, not a historical peak.
/// Stable keys are shared by saved controls, the monitor, and the helper.
public enum MaximumTemperature: String, CaseIterable {
    case cpu = "max:cpu"
    case gpu = "max:gpu"

    public var category: String { self == .cpu ? "cpu" : "gpu" }

    static func value(_ readings: [Double]) -> Double? {
        readings.filter(\.isFinite).max()
    }

    public func sensor(from readings: [Sensor]) -> Sensor? {
        let members = readings.filter {
            $0.category == category && $0.quantity == .temperature &&
            !$0.id.hasPrefix("avg:") && !$0.id.hasPrefix("max:")
        }
        guard !members.isEmpty else { return nil }
        let inferred = members.contains { $0.name.hasSuffix(" (inferred)") }
        var sensor = Sensor(id: rawValue,
                            name: "\(category.uppercased()) Maximum Temperature" + (inferred ? " (inferred)" : ""),
                            celsius: Self.value(members.compactMap(\.celsius)), category: category)
        if sensor.value == nil { sensor.issue = "No temperature readings are available in this group." }
        return sensor
    }
}

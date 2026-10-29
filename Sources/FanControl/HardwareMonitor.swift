import Foundation
import FanCore

struct HardwareSnapshot {
    var fans: [Fan]
    var sensors: [Sensor]
    var error: String?
}

protocol HardwareSampling {
    func sample(full: Bool) async -> HardwareSnapshot
}

// Mutable hardware state is confined to queue; callers receive value snapshots.
final class HardwareMonitor: HardwareSampling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.macsfancontrol.monitor", qos: .utility)
    private var hardware: MachineHardware?

    func sample(full: Bool = true) async -> HardwareSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    if self.hardware == nil { self.hardware = try MachineHardware() }
                    guard let hardware = self.hardware else { throw FanError.message("Hardware initialization failed.") }
                    let fans = try hardware.fans()
                    let sensors = try hardware.sensors(full: full)
                    continuation.resume(returning: HardwareSnapshot(fans: fans, sensors: sensors, error: nil))
                } catch {
                    self.hardware = nil
                    continuation.resume(returning: HardwareSnapshot(fans: [], sensors: [], error: error.localizedDescription))
                }
            }
        }
    }
}

enum DemoHardware {
    static func sample(tick: Int, modes: [Int: ControlMode]) -> HardwareSnapshot {
        let names: [(String, String, Double, String)] = [
            ("TA0P", "Ambient", 27, "temperature"), ("TB0T", "Battery", 31, "battery"),
            ("Tp01", "CPU Performance Core 1", 48, "cpu"), ("Tp05", "CPU Performance Core 2", 46, "cpu"),
            ("Tp09", "CPU Efficiency Core 1", 39, "cpu"), ("Tp0T", "CPU Efficiency Core 2", 38, "cpu"),
            ("Tg05", "GPU Cluster 1", 42, "gpu"), ("Tg0D", "GPU Cluster 2", 41, "gpu"),
            ("Th1H", "Heatsink Proximity", 36, "temperature"), ("Tm00", "Memory Bank 1", 37, "memory"),
            ("TPMP", "Power Supply Proximity", 34, "psu"), ("Ts0P", "Trackpad", 29, "temperature")
        ]
        var sensors = names.enumerated().map { index, item in
            Sensor(id: item.0, name: item.1, celsius: item.2 + sin(Double(tick + index) / 9) * 1.8, category: item.3)
        }
        sensors += MaximumTemperature.allCases.compactMap { $0.sensor(from: sensors) }
        let fans = (0..<2).map { id -> Fan in
            let minimum = id == 0 ? 1200 : 1200
            let maximum = id == 0 ? 5800 : 5800
            let mode = modes[id] ?? .automatic
            var rpm = 1800 + Int(sin(Double(tick) / 8) * 60)
            switch mode {
            case .automatic: break
            case .constant(let value): rpm = value
            case .sensor(let key, let start, let limit):
                let t = sensors.first { $0.id == key }?.celsius ?? start
                rpm = minimum + Int(max(0, min(1, (t - start) / (limit - start))) * Double(maximum - minimum))
            }
            return Fan(id: id, name: id == 0 ? "Left side" : "Right side", minimum: minimum, current: rpm, maximum: maximum, manual: mode != .automatic)
        }
        return HardwareSnapshot(fans: fans, sensors: sensors, error: nil)
    }
}

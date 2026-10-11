import Foundation

public protocol FanHardware: AnyObject {
    func fans() throws -> [Fan]
    func temperature(_ key: String) throws -> Double
    func setRPM(_ rpm: Int, fan: Fan) throws
    func setAutomatic(fan: Int) throws
}
extension AppleSMC: FanHardware {}

/// Owns only fans explicitly claimed by this session; it never resets another app's fans.
public final class ControlSession {
    private let hardware: FanHardware
    private var modes: [Int: ControlMode] = [:]
    private var controllers: [Int: TemperatureController] = [:]
    private var owned = Set<Int>()
    private var heartbeatTime: TimeInterval = 0
    private var recoveryPending = false
    public init(hardware: FanHardware) { self.hardware = hardware }
    public func heartbeat(now: TimeInterval) throws {
        // Renewal cannot revive a control session that expired during sleep.
        if !owned.isEmpty && now - heartbeatTime > 8 {
            try reset()
            throw FanError.message("The control session expired. Fans have returned to automatic control.")
        }
        heartbeatTime = now
    }

    public func apply(_ request: ControlRequest, now: TimeInterval) throws {
        if recoveryPending { try reset() }
        let fans = try hardware.fans()
        for (id, mode) in request.modes {
            guard let fan = fans.first(where: { $0.id == id }) else { throw FanError.message("Fan \(id) is unavailable.") }
            try mode.validate(for: fan)
            if case .sensor(let key, _, _) = mode { _ = try hardware.temperature(key) }
        }
        // Validate the complete request before any write. On partial failure release every claimed fan.
        do {
            for (id, mode) in request.modes {
                guard let fan = fans.first(where: { $0.id == id }) else { continue }
                switch mode {
                case .automatic:
                    try hardware.setAutomatic(fan: id); owned.remove(id); modes.removeValue(forKey: id)
                case .constant(let rpm):
                    owned.insert(id); try hardware.setRPM(rpm, fan: fan); modes[id] = mode
                case .sensor:
                    owned.insert(id); modes[id] = mode
                }
                controllers[id] = TemperatureController()
            }
            heartbeatTime = now
            try tick(now: now)
        } catch {
            let original = error
            do { try reset() } catch { throw FanError.message("\(original.localizedDescription) Automatic recovery also failed: \(error.localizedDescription)") }
            throw original
        }
    }
    public func tick(now: TimeInterval) throws {
        guard !owned.isEmpty else { return }
        if recoveryPending { try reset(); return }
        // A crashed GUI or a long sleep must not leave a stale manual setting behind.
        guard now - heartbeatTime <= 8 else {
            try reset()
            throw FanError.message("The control session expired. Fans have returned to automatic control.")
        }
        do {
            let fans = try hardware.fans()
            for (id, mode) in modes {
                guard let fan = fans.first(where: { $0.id == id }) else { throw FanError.message("A controlled fan disappeared.") }
                switch mode {
                case .automatic: break
                case .constant(let rpm):
                    // Skip redundant SMC writes while the hardware already holds the target.
                    if !fan.manual || fan.target != rpm { try hardware.setRPM(rpm, fan: fan) }
                case .sensor(let key, let start, let maximum):
                    let temperature = try hardware.temperature(key)
                    if let rpm = try controllers[id, default: TemperatureController()].update(temperature: temperature, fan: fan, start: start, maximum: maximum, now: now) {
                        try hardware.setRPM(rpm, fan: fan)
                    }
                }
            }
        } catch {
            let original = error
            do { try reset() } catch { throw FanError.message("\(original.localizedDescription) Automatic recovery also failed: \(error.localizedDescription)") }
            throw original
        }
    }
    public func reset() throws {
        recoveryPending = true
        modes = [:]; controllers = [:]
        var failures: [String] = []
        for id in owned.sorted() {
            do { try hardware.setAutomatic(fan: id); owned.remove(id); modes.removeValue(forKey: id); controllers.removeValue(forKey: id) }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw FanError.message(failures.joined(separator: "\n")) }
        recoveryPending = false
    }
}

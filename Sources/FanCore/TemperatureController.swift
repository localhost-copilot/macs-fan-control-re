import Foundation

/// Temperature-band controller based on the reference's hysteresis behavior.
/// Time is supplied by the caller so cooldown and refresh behavior are deterministic.
public struct TemperatureController {
    public private(set) var target: Int?
    private var lastTemperature: Int?
    private var direction = 0
    private var lastDirectionChange: TimeInterval = 0
    private var lastWrite: TimeInterval = -.infinity
    private var lastWritten: Int?
    public init() {}

    public mutating func update(temperature: Double?, fan: Fan, start: Double, maximum: Double, now: TimeInterval) throws -> Int? {
        guard let temperature, temperature.isFinite, temperature > 0, temperature < 127,
              start.isFinite, maximum.isFinite, start >= 0, maximum <= 110, maximum - start >= 1,
              fan.minimum >= 0, fan.maximum <= 30000, fan.maximum > fan.minimum else {
            throw FanError.message("Temperature control lost its sensor or valid hardware limits; restore automatic control.")
        }
        let t = Int(temperature)
        let slope = max(1, Int(Double(fan.maximum - fan.minimum) / (maximum - start)))
        let low = max(fan.minimum, min(fan.maximum - slope, fan.minimum + Int((Double(t) - start - 1) * Double(slope))))
        let high = min(fan.maximum, low + slope)
        if temperature >= maximum { target = fan.maximum }
        else if temperature <= start { target = fan.minimum }
        else if target == nil {
            target = (low...high).contains(fan.current) ? fan.current : low
            direction = 1; lastDirectionChange = now
        } else {
            let nextDirection = t > (lastTemperature ?? t) ? 1 : (t < (lastTemperature ?? t) ? -1 : direction)
            if nextDirection != direction && now - lastDirectionChange >= 11 {
                direction = nextDirection; lastDirectionChange = now
            }
            if now - lastDirectionChange >= 60 && nextDirection == direction {
                direction = temperature <= (start + maximum) / 2 ? -1 : 1
                lastDirectionChange = now
            }
            let current = target!
            if direction > 0 {
                let extra = low - current > 2 * slope ? slope / 3 : 0
                target = min(high, current + extra + (t > (lastTemperature ?? t) ? 4 : 2))
            } else if direction < 0 {
                let extra = current - high > slope ? slope / 3 : 0
                target = max(low, current - extra - 2)
            }
        }
        target = max(fan.minimum, min(fan.maximum, target ?? fan.minimum))
        lastTemperature = t
        guard target != lastWritten || now - lastWrite >= 31 else { return nil }
        lastWrite = now; lastWritten = target
        return target
    }
}

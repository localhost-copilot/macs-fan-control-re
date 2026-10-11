import SwiftUI
import FanCore

// Shared visual vocabulary for sensors and table rows.

func rowColor(_ index: Int) -> Color {
    Color(nsColor: index.isMultiple(of: 2) ? .textBackgroundColor : .alternatingContentBackgroundColors[1])
}
func sensorIcon(_ sensor: Sensor) -> String {
    if sensor.quantity != .temperature { return sensor.quantity == .power ? "bolt.fill" : "waveform.path" }
    switch sensor.category {
    case "cpu", "gpu": return "cpu"
    case "battery": return "battery.100percent"
    case "memory": return "memorychip"
    case "ssd": return "internaldrive"
    case "psu": return "bolt.fill"
    case "airport": return "wifi"
    default: return "thermometer.medium"
    }
}
func readingColor(_ sensor: Sensor) -> Color {
    guard let celsius = sensor.celsius else { return .primary }
    return celsius >= 90 ? .red : celsius >= 75 ? .orange : .primary
}
func sensorColor(_ sensor: Sensor) -> Color {
    switch sensor.category {
    case "cpu", "gpu": return .blue
    case "psu": return .orange
    case "memory", "battery", "ssd": return .green
    default: return .cyan
    }
}

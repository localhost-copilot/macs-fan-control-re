import SwiftUI
import ServiceManagement
import FanCore

enum MenuIconStyle: String, Codable, CaseIterable {
    case monochrome, colored, none
}

struct Preferences: Codable, Equatable {
    var unit: TemperatureUnit = .celsius
    var language = "en"
    var decimals = true
    var hideOnLaunch = false
    var showDockIcon = false
    var menuIconStyle = MenuIconStyle.monochrome
    var menuFan = true
    var menuTemperature = true
    var menuFanID = 0
    var menuSensor = ""
    var hiddenSensors: Set<String> = []
    var showUnknownSensors = false
}

// Settings saved by older builds lack newer keys; keep what they have instead of resetting everything.
extension Preferences {
    private enum LegacyKeys: String, CodingKey { case menuIcon }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        unit = try values.decodeIfPresent(TemperatureUnit.self, forKey: .unit) ?? defaults.unit
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
        decimals = try values.decodeIfPresent(Bool.self, forKey: .decimals) ?? defaults.decimals
        hideOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .hideOnLaunch) ?? defaults.hideOnLaunch
        showDockIcon = try values.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? defaults.showDockIcon
        let legacyIcon = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .menuIcon)
        menuIconStyle = try values.decodeIfPresent(MenuIconStyle.self, forKey: .menuIconStyle) ?? (legacyIcon == false ? .none : defaults.menuIconStyle)
        menuFan = try values.decodeIfPresent(Bool.self, forKey: .menuFan) ?? defaults.menuFan
        menuTemperature = try values.decodeIfPresent(Bool.self, forKey: .menuTemperature) ?? defaults.menuTemperature
        menuFanID = try values.decodeIfPresent(Int.self, forKey: .menuFanID) ?? defaults.menuFanID
        menuSensor = try values.decodeIfPresent(String.self, forKey: .menuSensor) ?? defaults.menuSensor
        hiddenSensors = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenSensors) ?? defaults.hiddenSensors
        showUnknownSensors = try values.decodeIfPresent(Bool.self, forKey: .showUnknownSensors) ?? defaults.showUnknownSensors
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var sensors: [Sensor] = []
    @Published var modes: [Int: ControlMode] = [:]
    @Published var presets: [Preset] = []
    @Published var activePreset = PresetName.automatic
    @Published var preferences = Preferences() { didSet { persistPreferences() } }
    @Published var demo: Bool
    @Published var busy = false
    @Published var loading = true
    @Published var monitorError: String?
    @Published var error: String?
    @Published var selectedFan: Fan?
    @Published var showAbout = false
    @Published var presetEditor: PresetEdit?
    @Published var log: [String] = []
    let helper = HelperClient()
    private let monitor = HardwareMonitor()
    private let defaults: UserDefaults
    private var polling: Task<Void, Never>?
    private var tick = 0
    private var refreshGeneration = 0
    private var installing: Task<Void, Error>?
    private struct SavedControl: Codable {
        var modes: [Int: ControlMode]
        var preset: String
    }
    private var pendingControl: SavedControl?
    // Keep simulated changes separate even when demo is toggled in the same process.
    private var controlKey: String { demo ? "demoControl" : "lastControl" }
    var showWindow: (() -> Void)?
    var hideWindow: (() -> Void)?
    var openPreferences: (() -> Void)?
    var statusChanged: (() -> Void)?

    init(defaults suppliedDefaults: UserDefaults? = nil, demoRequested: Bool = CommandLine.arguments.contains("--demo")) {
        demo = demoRequested
        defaults = suppliedDefaults ?? (demoRequested ? UserDefaults(suiteName: "local.macsfancontrol.swift.demo")! : .standard)
        if let data = defaults.data(forKey: "preferences"), let prefs = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = prefs }
        if let data = defaults.data(forKey: "presets"), let values = try? JSONDecoder().decode([Preset].self, from: data) { presets = values }
        if let data = defaults.data(forKey: controlKey) { pendingControl = try? JSONDecoder().decode(SavedControl.self, from: data) }
    }
    var unit: TemperatureUnit { preferences.unit }
    var visibleSensors: [Sensor] {
        sensors.filter { !preferences.hiddenSensors.contains($0.id) && (preferences.showUnknownSensors || $0.isVisibleByDefault) }
    }
    var controlSensors: [Sensor] { sensors.filter { $0.celsius != nil } }
    func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: preferences.decimals ? "%.1f" : "%.0f", unit.display(value))
    }
    func reading(_ sensor: Sensor) -> String {
        guard let value = sensor.value else { return "—" }
        if sensor.quantity == .temperature { return temperature(value) + " " + unit.symbol }
        return String(format: "%.3f", value) + " " + sensor.quantity.symbol
    }
    func quantityName(_ quantity: SensorQuantity) -> String {
        switch quantity {
        case .temperature: return text("Temperature", "温度")
        case .voltage: return text("Voltage", "电压")
        case .current: return text("Current", "电流")
        case .power: return text("Power", "功耗")
        }
    }
    func text(_ english: String, _ chinese: String) -> String { preferences.language == "zh" ? chinese : english }
    func modeDescription(_ fan: Fan) -> String {
        switch modes[fan.id] ?? .automatic {
        case .automatic: return fan.manual && !demo ? text("External control", "外部控制") : text("Auto", "自动")
        case .constant(let rpm): return text("Constant value of \(rpm)", "恒定转速 \(rpm)")
        case .sensor(let key, _, _): return text("Based on ", "基于 ") + (sensors.first { $0.id == key }?.name ?? key)
        }
    }
    /// Installs the helper on demand so fan control works without a separate setup step.
    /// Concurrent callers share one authorization prompt.
    func ensureHelper() async throws {
        guard !demo, !helper.available else { return }
        if installing == nil { installing = Task { try await helper.register() } }
        defer { installing = nil }
        try await installing!.value
        guard helper.available else {
            throw FanError.message(text("Approve the fan helper in System Settings → General → Login Items, then try again.", "请在“系统设置 → 通用 → 登录项”中允许风扇辅助程序，然后重试。"))
        }
        record("Fan control helper installed.")
    }
    func start() {
        polling = Task { [weak self] in
            if let self, !self.demo {
                // A cancelled prompt only defers installation until the first manual change.
                do { try await self.ensureHelper() } catch { self.record(error.localizedDescription) }
            }
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                if !demo && !modes.isEmpty {
                    do { try await helper.heartbeat() }
                    catch { self.error = error.localizedDescription; record(error.localizedDescription); releaseControl() }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        tick += 1
        // Unlisted raw channels only need an occasional pass while hidden.
        let full = preferences.showUnknownSensors || tick % 10 == 1
        let snapshot = demo ? DemoHardware.sample(tick: tick, modes: modes) : await monitor.sample(full: full)
        guard generation == refreshGeneration else { return }
        if fans != snapshot.fans { fans = snapshot.fans }
        if sensors != snapshot.sensors { sensors = snapshot.sensors }
        if monitorError != snapshot.error { monitorError = snapshot.error }
        if loading { loading = false }
        statusChanged?()
        await restoreControlIfReady()
    }
    private func restoreControlIfReady() async {
        guard !Task.isCancelled, !busy, monitorError == nil, !fans.isEmpty,
              let saved = pendingControl else { return }
        // Consume before applying: perform() refreshes, and a failed restore must not
        // retry every polling tick or take control again after a safety release.
        pendingControl = nil
        guard !saved.modes.isEmpty else { return }
        for mode in saved.modes.values {
            if case .sensor(let key, _, _) = mode,
               !sensors.contains(where: { $0.id == key && $0.celsius?.isFinite == true }) {
                error = text("Cannot restore fan control: the saved temperature sensor is unavailable.", "无法恢复风扇控制：保存的温度传感器不可用。")
                return
            }
        }
        // The normal apply path validates every fan and RPM before contacting the helper.
        await apply(saved.modes, preset: saved.preset)
    }
    @discardableResult
    func apply(_ changes: [Int: ControlMode], preset: String = PresetName.custom) async -> Bool {
        guard !busy else { return false }
        do { try await perform(changes, preset: preset); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    /// For interactive edits: waits for an in-flight change and reports failures to the caller instead of alerting.
    func applyLive(_ changes: [Int: ControlMode], preset: String = PresetName.custom) async -> String? {
        while busy {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if Task.isCancelled { return nil }
        do { try await perform(changes, preset: preset); return nil }
        catch { return error.localizedDescription }
    }
    private func perform(_ changes: [Int: ControlMode], preset: String) async throws {
        busy = true
        defer { busy = false }
        do {
            for (id, mode) in changes {
                guard let fan = fans.first(where: { $0.id == id }) else { throw FanError.message("Fan is no longer available.") }
                try mode.validate(for: fan)
            }
            if !demo {
                if changes.values.contains(where: { $0 != .automatic }) { try await ensureHelper() }
                // Without a helper this app owns no fans, so there is nothing to release.
                if helper.available { try await helper.apply(changes) }
            }
            for (id, mode) in changes {
                if mode == .automatic { modes.removeValue(forKey: id) } else { modes[id] = mode }
            }
            activePreset = modes.isEmpty ? PresetName.automatic : preset
            pendingControl = nil
            persistControl()
            record("Applied \(activePreset) to \(changes.count) fan(s).")
        } catch { record(error.localizedDescription); throw error }
        await refresh()
    }
    /// Text and icon shown in the menu bar; shared with the preferences preview.
    var statusDisplay: StatusDisplay {
        let prefs = preferences
        var segments: [StatusSegment] = []
        if prefs.menuFan, let fan = fans.first(where: { $0.id == prefs.menuFanID }) ?? fans.first {
            // Widest speed this fan can report, so the slot never resizes.
            segments.append(StatusSegment(value: String(fan.current), unit: "RPM", template: String(repeating: "8", count: max(4, String(max(fan.maximum, fan.current)).count)), tint: nil))
        }
        if prefs.menuTemperature, let sensor = sensors.first(where: { $0.id == prefs.menuSensor }) ?? visibleSensors.first(where: { $0.celsius != nil }) {
            if sensor.quantity == .temperature {
                let digits = unit == .fahrenheit ? "888" : "88"
                segments.append(StatusSegment(value: temperature(sensor.value), unit: unit.symbol, template: preferences.decimals ? digits + ".8" : digits,
                                              tint: sensor.celsius.flatMap(StatusItemRenderer.temperatureTint)))
            } else {
                segments.append(StatusSegment(value: sensor.value.map { String(format: "%.2f", $0) } ?? "—", unit: sensor.quantity.symbol, template: "888.88", tint: nil))
            }
        }
        // A status item with neither text nor icon would be impossible to click.
        let icon = prefs.menuIconStyle == .none && segments.isEmpty ? .monochrome : prefs.menuIconStyle
        let manual = !modes.isEmpty || (!demo && fans.contains { $0.manual })
        return StatusDisplay(segments: segments, icon: icon, manual: manual, demo: demo)
    }
    /// Forget local control state after the helper has already returned fans to automatic.
    /// Keep the saved choice for the next launch, but never restore again this session.
    func releaseControl() {
        pendingControl = nil
        modes = [:]; activePreset = PresetName.automatic
    }
    func applyPreset(_ name: String) async {
        let changes: [Int: ControlMode]
        if name == PresetName.automatic { changes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .automatic) }) }
        else if name == PresetName.fullBlast { changes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, .constant($0.maximum)) }) }
        else if let preset = presets.first(where: { $0.name == name }) {
            guard Set(preset.modes.keys).isSubset(of: Set(fans.map(\.id))) else { error = "This preset contains fans that are not available on this Mac."; return }
            changes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, preset.modes[$0.id] ?? .automatic) })
        } else { return }
        await apply(changes, preset: name)
    }
    func savePreset(name: String, replacing id: UUID? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !PresetName.reserved.contains(name),
              !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame && $0.id != id }) else {
            throw FanError.message("Enter a unique preset name (1–60 characters).")
        }
        if let id, let index = presets.firstIndex(where: { $0.id == id }) {
            if activePreset == presets[index].name { activePreset = name }
            presets[index].name = name
        } else {
            guard !modes.isEmpty else { throw FanError.message("Change at least one fan to Custom before saving a preset.") }
            presets.append(Preset(name: name, modes: modes)); activePreset = name
        }
        if !modes.isEmpty { persistControl() }
        persist(); statusChanged?()
    }
    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        if activePreset == preset.name { activePreset = modes.isEmpty ? PresetName.automatic : PresetName.custom }
        if !modes.isEmpty { persistControl() }
        persist(); statusChanged?()
    }
    func switchDemo(_ enabled: Bool) async {
        guard enabled != demo, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if !demo { try await helper.reset() }
            releaseControl(); demo = enabled; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func prepareToQuit() async -> Bool {
        pendingControl = nil
        polling?.cancel()
        do { if !demo { try await helper.reset() }; return true }
        catch { self.error = error.localizedDescription; start(); return false }
    }
    func record(_ message: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
    func persist() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }
        persistPreferences()
    }
    private func persistControl() {
        if let data = try? JSONEncoder().encode(SavedControl(modes: modes, preset: activePreset)) {
            defaults.set(data, forKey: controlKey)
        }
    }
    private func persistPreferences() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences") }
        statusChanged?()
    }
}

/// Built-in preset names. They double as persisted identifiers, so never localize these values.
enum PresetName {
    static let automatic = "Automatic"
    static let fullBlast = "Full blast"
    static let custom = "Custom*"
    static let reserved = [automatic, fullBlast, custom]
}

struct PresetEdit: Identifiable {
    let id = UUID()
    var preset: Preset?
}

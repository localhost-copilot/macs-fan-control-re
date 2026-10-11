import SwiftUI
import FanCore

struct FanControlSheet: View {
    @ObservedObject var model: AppModel
    let fan: Fan
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var rpm = 2000.0
    @State private var sensor = ""
    @State private var start = 40.0
    @State private var maximum = 80.0
    @State private var rpmInput = "2000"
    @State private var startInput = "40"
    @State private var maximumInput = "80"
    @State private var saveToPreset = false
    @State private var failure: String?
    // Edits apply live; Cancel restores what was in effect when the sheet opened.
    @State private var original: ControlMode = .automatic
    @State private var originalPreset = PresetName.automatic
    @State private var baseline: ControlMode?
    @State private var lastApplied: ControlMode = .automatic
    @State private var touched = false
    @State private var pending: Task<Void, Never>?
    private var liveFan: Fan { model.fans.first { $0.id == fan.id } ?? fan }

    private var selectedMode: ControlMode {
        if mode == 0 {
            let value = Double(rpmInput) ?? .nan
            let safeRPM = value.isFinite && value >= 0 && value <= 30000 ? Int(value) : -1
            return .constant(safeRPM)
        }
        return .sensor(key: sensor, start: model.unit.celsius(Double(startInput) ?? .nan), maximum: model.unit.celsius(Double(maximumInput) ?? .nan))
    }
    private var valid: Bool { (try? selectedMode.validate(for: fan)) != nil && (mode == 0 || !sensor.isEmpty) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.text("Change fan control for the ‘\(fan.name)’ fan", "更改“\(fan.name)”风扇控制")).font(.headline)
                    HStack(spacing: 4) {
                        Text("\(fan.minimum) – \(fan.maximum) RPM ·")
                        Text(model.text("now \(liveFan.current) RPM", "当前 \(liveFan.current) RPM")).monospacedDigit().foregroundStyle(touched ? Color.orange : Color.secondary)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $mode) {
                Text(model.text("Constant RPM value", "恒定 RPM 值")).tag(0)
                Text(model.text("Sensor-based value", "基于传感器的值")).tag(1)
            }.pickerStyle(.radioGroup).labelsHidden()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Slider(value: rpmBinding, in: Double(fan.minimum)...Double(max(fan.minimum + 1, fan.maximum)))
                    TextField("RPM", text: $rpmInput).frame(width: 68).accessibilityIdentifier("rpm-input")
                    Stepper("RPM", value: rpmBinding, in: Double(fan.minimum)...Double(max(fan.minimum + 1, fan.maximum)), step: 50).labelsHidden()
                    Text("RPM").foregroundStyle(.secondary)
                }
                HStack { Text("\(fan.minimum)"); Spacer(); Text("\(fan.maximum)") }.font(.caption).foregroundStyle(.secondary).padding(.trailing, 132)
            }.disabled(mode != 0)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Picker(model.text("Sensor:", "传感器："), selection: $sensor) {
                    Text(model.text("Select a sensor", "选择传感器")).tag("")
                    ForEach(sensorChoices) { sensor in
                        Text("\(model.sensorName(sensor)) (\(model.temperature(sensor.celsius))\(model.unit.symbol))").tag(sensor.id).help(model.sensorHelp(sensor))
                    }
                }
                HStack {
                    Text(model.text("Temperature that the fan speed will start to increase from:", "风扇开始加速的温度：")).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    temperatureField($startInput)
                }
                HStack {
                    Text(model.text("Maximum temperature:", "最高温度：")); Spacer(); temperatureField($maximumInput)
                }
            }.disabled(mode != 1).opacity(mode == 1 ? 1 : 0.45)
            CurvePreview(minimumRPM: fan.minimum, maximumRPM: fan.maximum, start: Double(startInput) ?? 0, maximum: Double(maximumInput) ?? 0,
                         constant: mode == 0 ? rpmBinding.wrappedValue : nil, rpm: liveFan.current,
                         current: model.sensors.first { $0.id == sensor }?.celsius.map(model.unit.display), range: model.unit.display(0)...model.unit.display(110), unit: model.unit.symbol)
                .frame(height: 110)
            if let preset = model.presets.first(where: { $0.name == model.activePreset }) {
                Toggle(model.text("Save to the current preset (‘\(preset.name)’)", "保存到当前预设（“\(preset.name)”）"), isOn: $saveToPreset)
            }
            if fan.maximum <= fan.minimum {
                Text(model.text("The fan’s minimum and maximum speeds are equal. Custom control is unavailable.", "此风扇的最低和最高转速相同，无法使用自定义控制。")).foregroundStyle(.orange)
            }
            if !valid && fan.maximum > fan.minimum {
                Text(model.text("Enter a valid RPM, or choose a sensor with a maximum temperature at least 1°C above the start temperature.", "请输入有效转速，或选择传感器并确保最高温度至少比起始温度高 1°C。")).font(.caption).foregroundStyle(.orange)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if model.demo { Text(model.text("Demo mode: no hardware changes will be made.", "演示模式：不会更改实际硬件。")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(model.text("Cancel", "取消")) {
                    pending?.cancel()
                    Task {
                        if touched, lastApplied != original { _ = await model.applyLive([fan.id: original], preset: originalPreset) }
                        dismiss()
                    }
                }.keyboardShortcut(.cancelAction)
                Button(model.text("OK", "好")) {
                    pending?.cancel()
                    Task {
                        let name = saveToPreset ? originalPreset : PresetName.custom
                        if let message = await model.applyLive([fan.id: selectedMode], preset: name) { failure = message; return }
                        if saveToPreset, let index = model.presets.firstIndex(where: { $0.name == name }) {
                            model.presets[index].modes[fan.id] = selectedMode; model.persist()
                        }
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(22).frame(width: 485).textFieldStyle(.roundedBorder)
            .onChange(of: selectedMode) { _ in scheduleLiveApply() }
            .onAppear {
                original = model.modes[fan.id] ?? .automatic
                originalPreset = model.activePreset
                lastApplied = original
                rpm = Double(max(fan.minimum, min(fan.maximum, fan.current)))
                let preferred = sensorChoices.first { $0.id.hasPrefix("avg:") && $0.category == "cpu" } ?? sensorChoices.first { $0.category == "cpu" }
                sensor = (preferred ?? sensorChoices.first)?.id ?? ""
                start = model.unit.display(40); maximum = model.unit.display(80)
                if let existing = model.modes[fan.id] {
                    switch existing {
                    case .constant(let value): rpm = Double(value)
                    case .sensor(let key, let low, let high): mode = 1; sensor = key; start = model.unit.display(low); maximum = model.unit.display(high)
                    case .automatic: break
                    }
                }
                rpmInput = String(Int(rpm))
                startInput = String(format: "%g", start)
                maximumInput = String(format: "%g", maximum)
                baseline = selectedMode
            }
    }
    /// Debounced so dragging the slider sends one request per pause, not per pixel.
    private func scheduleLiveApply() {
        guard let baseline, touched || selectedMode != baseline else { return }
        touched = true
        pending?.cancel()
        guard valid else { return }
        let mode = selectedMode
        pending = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, mode != lastApplied else { return }
            if let message = await model.applyLive([fan.id: mode]) { failure = message }
            else { failure = nil; lastApplied = mode }
        }
    }
    // Offer the listed sensors, not every raw channel, but keep a hidden selection reachable.
    private var sensorChoices: [Sensor] {
        let visible = Set(model.visibleSensors.map(\.id))
        return model.controlSensors.filter { visible.contains($0.id) || $0.id == sensor }
    }
    private var rpmBinding: Binding<Double> {
        Binding(get: { max(Double(fan.minimum), min(Double(fan.maximum), Double(rpmInput) ?? Double(fan.minimum))) }, set: { rpmInput = String(Int($0.rounded())) })
    }
    private func temperatureField(_ input: Binding<String>) -> some View {
        let numeric = Binding<Double>(get: { Double(input.wrappedValue) ?? model.unit.display(0) }, set: { input.wrappedValue = String(format: "%g", $0) })
        return HStack(spacing: 4) {
            TextField("", text: input).frame(width: 54)
            Stepper("", value: numeric, in: model.unit.display(0)...model.unit.display(110), step: 1).labelsHidden()
            Text(model.unit.symbol)
        }
    }
}

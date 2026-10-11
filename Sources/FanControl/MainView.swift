import SwiftUI
import FanCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""
    @State private var ascending = true
    @State private var sortByValue = false
    @State private var selectedSensor: String?
    @State private var quantityFilter = "all"
    @State private var showUnavailable = true

    private var sortedSensors: [Sensor] {
        let values = model.visibleSensors.filter {
            (quantityFilter == "all" || $0.quantity.rawValue == quantityFilter) &&
            (showUnavailable || $0.value != nil) &&
            (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter) || $0.source.localizedCaseInsensitiveContains(filter))
        }
        return values.sorted {
            if sortByValue {
                if $0.quantity != $1.quantity { return $0.quantity.rawValue < $1.quantity.rawValue }
                if $0.value != $1.value { return ascending ? ($0.value ?? -.infinity) < ($1.value ?? -.infinity) : ($0.value ?? -.infinity) > ($1.value ?? -.infinity) }
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison == .orderedSame { return $0.id < $1.id }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.demo {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                    Text(model.text("Demo mode — simulated fans and temperatures", "演示模式 — 模拟风扇及温度数据"))
                    Spacer()
                    Button(model.text("Use real sensors", "使用真实传感器")) { Task { await model.switchDemo(false) } }
                        .buttonStyle(.link)
                }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6).background(Color.accentColor.opacity(0.09))
            }
            HSplitView {
                fanPane.frame(minWidth: 490, idealWidth: 510)
                sensorPane(sortedSensors).frame(minWidth: 270, idealWidth: 300)
            }.padding(.horizontal, 10).padding(.top, 6)
            HStack(spacing: 12) {
                if model.loading { ProgressView().controlSize(.small); Text(model.text("Reading sensors…", "正在读取传感器…")).font(.caption) }
                else {
                    Circle().fill(model.monitorError != nil ? Color.orange : model.demo || model.helper.available ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(model.demo ? model.text("Demo", "演示") : model.helper.available ? model.text("Connected", "已连接") : model.text("Monitoring only", "仅监控"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(model.text("Hide to menu bar", "隐藏到菜单栏")) { model.hideWindow?() }
                Button(model.text("Preferences…", "偏好设置…")) { model.openPreferences?() }
                Button { model.showAbout = true } label: { Image(systemName: "questionmark.circle").font(.system(size: 15)) }.buttonStyle(.plain).help(model.text("About", "关于"))
            }.padding(10)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 790, minHeight: 380)
        .sheet(item: $model.selectedFan) { fan in FanControlSheet(model: model, fan: fan) }
        .sheet(isPresented: $model.showAbout) { AboutView(model: model) }
        .sheet(item: $model.presetEditor) { edit in PresetSheet(model: model, edit: edit) }
        .alert(model.text("Macs Fan Control", "Macs Fan Control"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(model.text("OK", "好")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var fanPane: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Text(model.text("Active preset:", "当前预设："))
                Picker("", selection: Binding(get: { model.activePreset }, set: { name in Task { await model.applyPreset(name) } })) {
                    Text(model.text("Automatic", "自动")).tag(PresetName.automatic)
                    Text(model.text("Full blast", "全速")).tag(PresetName.fullBlast)
                    if model.activePreset == PresetName.custom { Text(model.text("Custom*", "自定义*")).tag(PresetName.custom) }
                    ForEach(model.presets) { Text($0.name).tag($0.name) }
                }.labelsHidden().frame(width: 142).disabled(model.busy || model.fans.isEmpty)
                Menu {
                    Button(model.text("Save current preset…", "保存当前预设…")) { model.presetEditor = PresetEdit() }.disabled(model.modes.isEmpty)
                    if let preset = model.presets.first(where: { $0.name == model.activePreset }) {
                        Button(model.text("Rename…", "重命名…")) { model.presetEditor = PresetEdit(preset: preset) }
                        Button(model.text("Delete", "删除")) { model.deletePreset(preset) }
                    }
                    Divider()
                    Button(model.text("Discard (reset all fans to auto)", "放弃更改（所有风扇恢复自动）")) { Task { await model.applyPreset(PresetName.automatic) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).disabled(model.busy)
                Spacer(minLength: 0)
            }.frame(height: 32)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(model.text("Fan", "风扇")).padding(.leading, 10).frame(width: 110, alignment: .leading)
                    Divider().frame(height: 17)
                    Text(model.text("Min/Current/Max RPM", "最低/当前/最高 RPM")).font(.system(size: 11)).frame(width: 148)
                    Divider().frame(height: 17)
                    Text(model.text("Control", "控制")).frame(maxWidth: .infinity)
                }.frame(height: 22).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.fans.enumerated()), id: \.element.id) { index, fan in
                                FanRow(model: model, fan: fan).frame(height: 42).background(rowColor(index))
                            }
                            if model.fans.isEmpty && !model.loading {
                                VStack(spacing: 10) {
                                    Image(systemName: "fan").font(.system(size: 28)).foregroundStyle(.secondary)
                                    Text(model.monitorError ?? model.text("No fans detected on this computer.", "此电脑未检测到风扇。"))
                                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                    Button(model.text("Explore demo mode", "体验演示模式")) { Task { await model.switchDemo(true) } }
                                }.padding(24).frame(maxWidth: .infinity)
                            }
                            ForEach(0..<max(1, Int(geometry.size.height / 42) - model.fans.count), id: \.self) { index in
                                rowColor(index + model.fans.count).frame(height: 42)
                            }
                        }
                    }
                }.background(Color(nsColor: .textBackgroundColor))
            }.border(Color(nsColor: .separatorColor))
        }
    }
    // Sorting hundreds of channels is the main view's hot path; do it once per render.
    private func sensorPane(_ rows: [Sensor]) -> some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Picker(model.text("Sensors", "传感器"), selection: $quantityFilter) {
                    Text(model.text("All sensors", "全部传感器")).tag("all")
                    ForEach(SensorQuantity.allCases, id: \.self) { quantity in
                        Text(model.quantityName(quantity)).tag(quantity.rawValue)
                    }
                }.labelsHidden().frame(maxWidth: 175)
                Spacer(minLength: 0)
                Menu {
                    Toggle(model.text("Show all raw channels", "显示全部原始通道"), isOn: $model.preferences.showUnknownSensors)
                    Toggle(model.text("Show unavailable channels", "显示不可用通道"), isOn: $showUnavailable)
                    Button(model.text("Configure sensors…", "配置传感器…")) { model.openPreferences?() }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            }.frame(height: 32)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { sortByValue = false; ascending.toggle() } label: {
                        sortHeader(model.text("Sensor", "传感器"), active: !sortByValue, ascending: ascending).padding(.leading, 34).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Divider().frame(height: 17)
                    Button { sortByValue = true; ascending.toggle() } label: {
                        sortHeader(model.text("Value", "数值"), active: sortByValue, ascending: ascending).padding(.trailing, 7).frame(width: 90, alignment: .trailing)
                    }.buttonStyle(.plain)
                }.frame(height: 22).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, sensor in
                                HStack(spacing: 9) {
                                    Image(systemName: sensorIcon(sensor)).foregroundStyle(sensorColor(sensor)).frame(width: 18)
                                    Text(sensor.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(model.reading(sensor)).monospacedDigit().foregroundStyle(readingColor(sensor)).frame(width: 84, alignment: .trailing)
                                }.padding(.horizontal, 7).frame(height: 23)
                                    .background(selectedSensor == sensor.id ? Color.accentColor.opacity(0.18) : rowColor(index))
                                    .contentShape(Rectangle()).onTapGesture { selectedSensor = sensor.id }
                                    .help("\(sensor.name) · \(sensor.source) · \(sensor.id)\n\(sensor.issue ?? model.reading(sensor))")
                                    .contextMenu {
                                        Button(model.text("Show in menu bar", "在菜单栏显示")) { model.preferences.menuSensor = sensor.id; model.preferences.menuTemperature = true }
                                        Button(model.text("Copy sensor value", "复制传感器数值")) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString("\(sensor.name): \(model.reading(sensor)) [\(sensor.source): \(sensor.id)]", forType: .string)
                                        }
                                        Button(model.text("Hide sensor", "隐藏传感器")) { model.preferences.hiddenSensors.insert(sensor.id) }
                                    }
                            }
                            ForEach(0..<max(1, Int(geometry.size.height / 23) - rows.count), id: \.self) { index in
                                rowColor(index + rows.count).frame(height: 23)
                            }
                        }
                    }
                    if rows.isEmpty && !model.loading {
                        VStack(spacing: 6) {
                            Text(model.text("No matching sensors", "没有匹配的传感器"))
                            Button(model.text("Show all sensors", "显示所有传感器")) { model.preferences.hiddenSensors = []; model.preferences.showUnknownSensors = true; filter = ""; quantityFilter = "all"; showUnavailable = true }
                        }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.background(Color(nsColor: .textBackgroundColor))
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.text("Filter sensors", "筛选传感器"), text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    let readable = rows.filter { $0.value != nil }.count
                    Text(readable == rows.count ? "\(rows.count)" : "\(readable)/\(rows.count)").monospacedDigit().foregroundStyle(.secondary)
                        .help(model.text("\(readable) readable / \(rows.count) channels", "\(readable) 可读 / \(rows.count) 个通道"))
                }.font(.system(size: 11)).padding(.horizontal, 7).frame(height: 24)
            }.border(Color(nsColor: .separatorColor))
        }
    }
}

private func sortHeader(_ title: String, active: Bool, ascending: Bool) -> some View {
    HStack(spacing: 3) {
        Text(title)
        if active { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
    }
}

private struct FanRow: View {
    @ObservedObject var model: AppModel
    let fan: Fan
    private var controlled: Bool { model.modes[fan.id] != nil || fan.manual }
    private var fraction: CGFloat {
        guard fan.maximum > fan.minimum else { return 0 }
        return CGFloat(max(0, min(1, Double(fan.current - fan.minimum) / Double(fan.maximum - fan.minimum))))
    }
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "fan.fill").font(.system(size: 25)).foregroundStyle(controlled ? Color.orange : Color.gray)
                Text(fan.name).font(.system(size: 12)).lineLimit(2)
            }.padding(.leading, 6).frame(width: 110, alignment: .leading)
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text(String(fan.minimum)).font(.system(size: 10)).frame(width: 28, alignment: .trailing)
                    Text("—").font(.system(size: 11))
                    Text(String(fan.current)).font(.system(size: 14, weight: .bold)).frame(width: 40)
                    Text("—").font(.system(size: 11))
                    Text(String(fan.maximum)).font(.system(size: 10)).frame(width: 28, alignment: .leading)
                }.monospacedDigit()
                // Where the current speed sits within the hardware range.
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(controlled ? Color.orange : Color.accentColor)
                                .frame(width: max(4, geometry.size.width * fraction))
                        }
                }.frame(width: 118, height: 3)
            }.frame(width: 149)
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    Button(model.text("Auto", "自动")) { Task { await model.apply([fan.id: .automatic]) } }
                        .accessibilityIdentifier("fan-\(fan.id)-auto")
                        .buttonStyle(ControlSegment(active: (model.modes[fan.id] ?? .automatic) == .automatic && !fan.manual))
                        .help(model.text("Automatic (controlled by system)", "自动（由系统控制）"))
                    Button(model.text("Custom…", "自定义…")) { model.selectedFan = fan }
                        .accessibilityIdentifier("fan-\(fan.id)-custom")
                        .buttonStyle(ControlSegment(active: model.modes[fan.id] != nil || fan.manual))
                }.background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 6))
                if model.modes[fan.id] != nil || fan.manual {
                    Text(model.modeDescription(fan)).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
            }.padding(.horizontal, 9).frame(maxWidth: .infinity).disabled(model.busy)
        }.help(model.text("Target: \(fan.target.map(String.init) ?? "—") RPM · Mode: \(fan.modeKey ?? "unavailable")", "目标：\(fan.target.map(String.init) ?? "—") RPM · 模式键：\(fan.modeKey ?? "不可用")"))
            .contentShape(Rectangle()).onTapGesture(count: 2) { model.selectedFan = fan }
            .contextMenu {
                Button(model.text("Change control…", "更改控制…")) { model.selectedFan = fan }
                Button(model.text("Reset to automatic control", "恢复自动控制")) { Task { await model.apply([fan.id: .automatic]) } }
            }
    }
}

private struct ControlSegment: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 23)
            .background(active ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(active ? 0.16 : 0), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

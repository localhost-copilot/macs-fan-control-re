import SwiftUI
import ServiceManagement
import FanCore

enum PreferencesPage: CaseIterable {
    case general, sensors, menuBar, advanced
    @MainActor func title(_ model: AppModel) -> String {
        switch self {
        case .general: return model.text("General", "通用")
        case .sensors: return model.text("T° Sensors", "温度传感器")
        case .menuBar: return model.text("Menu bar display", "菜单栏显示")
        case .advanced: return model.text("Advanced", "高级")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .sensors: return "thermometer.medium"
        case .menuBar: return "menubar.rectangle"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    let page: PreferencesPage
    @State private var failure: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var sensorFilter = ""
    @State private var helperBusy = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .general: general
            case .sensors: sensors
            case .menuBar: menuBar
            case .advanced: advanced
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 40).padding(.vertical, 28)
        .frame(width: page == .advanced ? 560 : 480, alignment: .leading)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.text("Autostart minimized when you log in (recommended)", "登录时自动最小化启动（推荐）"), isOn: Binding(get: { launchAtLogin && model.preferences.hideOnLaunch }, set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    model.preferences.hideOnLaunch = enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { failure = error.localizedDescription }
            }))
            Toggle(model.text("Show icon in dock", "在程序坞中显示图标"), isOn: $model.preferences.showDockIcon)
            HStack(spacing: 10) {
                Text(model.text("Language:", "语言："))
                Picker("", selection: $model.preferences.language) {
                    Text("English").tag("en"); Text("简体中文").tag("zh")
                }.labelsHidden().frame(width: 200)
            }.padding(.top, 8)
        }.toggleStyle(.checkbox)
    }

    private var sensors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.text("Use Fahrenheit temperature scale", "使用华氏温标"), isOn: Binding(get: { model.unit == .fahrenheit }, set: { model.preferences.unit = $0 ? .fahrenheit : .celsius }))
            Toggle(model.text("Precise display of temperature when possible (e.g. 45.4)", "尽可能精确显示温度（例如 45.4）"), isOn: $model.preferences.decimals)
            Toggle(model.text("Show all raw sensor channels", "显示全部原始传感器通道"), isOn: $model.preferences.showUnknownSensors)
            Divider().padding(.vertical, 4)
            HStack {
                Text(model.text("Shown in the main window", "在主窗口中显示")).font(.subheadline.weight(.medium))
                Spacer()
                TextField(model.text("Filter", "筛选"), text: $sensorFilter).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            List(model.sensors.filter { ($0.isVisibleByDefault || model.preferences.showUnknownSensors) && (sensorFilter.isEmpty || model.sensorName($0).localizedCaseInsensitiveContains(sensorFilter) || $0.id.localizedCaseInsensitiveContains(sensorFilter)) }) { sensor in
                Toggle(isOn: Binding(get: { !model.preferences.hiddenSensors.contains(sensor.id) }, set: { visible in
                    if visible { model.preferences.hiddenSensors.remove(sensor.id) } else { model.preferences.hiddenSensors.insert(sensor.id) }
                })) {
                    HStack {
                        Image(systemName: sensorIcon(sensor)).foregroundStyle(sensorColor(sensor)).frame(width: 16)
                        Text(model.sensorName(sensor)).lineLimit(1)
                        Spacer()
                        Text(model.reading(sensor)).monospacedDigit().foregroundStyle(.secondary)
                    }.help(model.sensorHelp(sensor))
                }
            }.listStyle(.bordered(alternatesRowBackgrounds: true)).frame(height: 190)
        }.toggleStyle(.checkbox)
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live preview of the status item using the same rendering inputs.
            HStack {
                Spacer()
                let preview = StatusItemRenderer.image(model.statusDisplay)
                Image(nsImage: preview)
                    .renderingMode(preview.isTemplate ? .template : .original).foregroundStyle(Color.primary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text(model.text("Icon:", "图标：")).gridColumnAlignment(.trailing)
                    Picker("", selection: $model.preferences.menuIconStyle) {
                        Label(model.text("Monochrome", "单色"), systemImage: "fan").tag(MenuIconStyle.monochrome)
                        Label(model.text("Colored", "彩色"), systemImage: "fan.fill").tag(MenuIconStyle.colored)
                        Text(model.text("None", "无")).tag(MenuIconStyle.none)
                    }.labelsHidden()
                }
                GridRow {
                    Text(model.text("Fan:", "风扇："))
                    Picker("", selection: Binding(get: { model.preferences.menuFan ? model.preferences.menuFanID : -1 }, set: { id in
                        model.preferences.menuFan = id >= 0
                        if id >= 0 { model.preferences.menuFanID = id }
                    })) {
                        Text(model.text("None", "无")).tag(-1)
                        Divider()
                        ForEach(model.fans) { Text("\($0.name) (\($0.current) RPM)").tag($0.id) }
                    }.labelsHidden()
                }
                GridRow {
                    Text(model.text("Sensor:", "传感器："))
                    Picker("", selection: Binding(get: { model.preferences.menuTemperature ? model.preferences.menuSensor : "-" }, set: { id in
                        model.preferences.menuTemperature = id != "-"
                        if id != "-" { model.preferences.menuSensor = id }
                    })) {
                        Text(model.text("None", "无")).tag("-")
                        Text(model.text("Automatic", "自动")).tag("")
                        Divider()
                        ForEach(model.visibleSensors.filter { $0.value != nil || $0.id == model.preferences.menuSensor }) {
                            Text("\(model.sensorName($0)) (\(model.reading($0)))").tag($0.id).help(model.sensorHelp($0))
                        }
                    }.labelsHidden()
                }
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text("Fan control helper", "风扇控制辅助程序")).font(.headline)
            Label(model.helper.available ? model.text("Installed and running", "已安装并运行") : model.text("Not installed", "未安装"),
                  systemImage: model.helper.available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(model.helper.available ? Color.green : Color.orange)
            Text(model.text("The helper is installed automatically at launch and when you first change a fan; macOS asks for an administrator password once.", "辅助程序会在启动时或首次调整风扇时自动安装，macOS 只需验证一次管理员密码。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !model.helper.available {
                    Button(model.text("Install now", "立即安装")) {
                        Task {
                            helperBusy = true
                            defer { helperBusy = false }
                            do { try await model.ensureHelper(); await model.refresh() } catch { failure = error.localizedDescription }
                        }
                    }.disabled(helperBusy)
                }
                Button(model.text("Remove helper…", "移除辅助程序…")) { showRemoveConfirmation = true }.disabled(!model.helper.available)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text(model.text("Diagnostics", "诊断")).font(.headline)
                Spacer()
                Text("\(Hardware.model) · \(model.fans.count) " + model.text("fans", "个风扇") + " · \(model.sensors.count) " + model.text("channels", "个通道"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.monitorError { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollView {
                Text(model.log.isEmpty ? model.text("No control events recorded.", "尚无控制事件记录。") : model.log.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 110).background(Color(nsColor: .textBackgroundColor)).border(Color(nsColor: .separatorColor))
            HStack {
                Button(model.text("Export diagnostics…", "导出诊断信息…")) { Diagnostics.export(model: model) }
                Spacer()
                Button(model.text("Clear log", "清除日志")) { model.log = [] }
            }
        }
        .confirmationDialog(model.text("Remove this app’s fan helper? All owned fans will return to automatic control.", "移除此应用的风扇辅助程序？应用控制的风扇将恢复自动模式。"), isPresented: $showRemoveConfirmation) {
            Button(model.text("Remove helper", "移除辅助程序"), role: .destructive) {
                Task {
                    do { try await model.helper.unregister(); model.releaseControl() }
                    catch { failure = error.localizedDescription }
                }
            }
        }
    }
}

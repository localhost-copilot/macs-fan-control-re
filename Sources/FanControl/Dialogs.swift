import SwiftUI
import FanCore

struct PresetSheet: View {
    @ObservedObject var model: AppModel
    let edit: PresetEdit
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.preset == nil ? model.text("Save custom preset", "保存自定义预设") : model.text("Edit preset name", "编辑预设名称")).font(.headline)
            HStack { Text(model.text("Preset name:", "预设名称：")); TextField("", text: $name).textFieldStyle(.roundedBorder) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(model.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.text("Save", "保存")) {
                    do { try model.savePreset(name: name, replacing: edit.preset?.id); dismiss() }
                    catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 360).onAppear { name = edit.preset?.name ?? "" }
    }
}

struct AboutView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Macs Fan Control").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · \(Hardware.model)").foregroundStyle(.secondary)
            Text(model.text("A native fan monitoring and control app. Custom presets are included.", "原生风扇监控与控制应用，包含自定义预设功能。"))
                .multilineTextAlignment(.center)
            Text(model.text("Not affiliated with CrystalIDEA. Original product names belong to their respective owners.", "本项目与 CrystalIDEA 无关联，原产品名称归其所有者所有。"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Link(model.text("Original Macs Fan Control website", "原版 Macs Fan Control 网站"), destination: URL(string: "https://crystalidea.com/macs-fan-control")!)
            Button(model.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(28).frame(width: 370)
    }
}

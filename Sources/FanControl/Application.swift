import AppKit
import SwiftUI
import FanCore

@main
enum FanControlApplication {
    static func main() {
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--probe-json") {
            do {
                let hardware = try MachineHardware()
                let fans = try hardware.fans()
                _ = try hardware.sensors()
                Thread.sleep(forTimeInterval: 1)
                let sensors = try hardware.sensors()
                if CommandLine.arguments.contains("--probe-json") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    struct Inventory: Encodable { let model: String; let fans: [Fan]; let sensors: [Sensor] }
                    print(String(decoding: try encoder.encode(Inventory(model: Hardware.model, fans: fans, sensors: sensors)), as: UTF8.self))
                    return
                }
                let valid = sensors.map { sensor in
                    "\(sensor.name) [\(sensor.source):\(sensor.id)]: " + (sensor.value.map { String(format: "%.3f", $0) + " " + sensor.quantity.symbol } ?? "unavailable: \(sensor.issue ?? "no reading")")
                }
                print("Model: \(Hardware.model)\nFans: \(fans.count)\n" + fans.map { "\($0.name): \($0.minimum) / \($0.current) / \($0.maximum) RPM" }.joined(separator: "\n"))
                print(valid.joined(separator: "\n"))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var actions: [() -> Void] = []
    private var quitting = false
    private var preferencesWindow: NSWindow?
    private var lastStatus: StatusDisplay?
    private var lastAppearance: NSAppearance?
    private var preferencesLanguage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 430), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Macs Fan Control · Swift (\(Hardware.model))"
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.minSize = NSSize(width: 810, height: 410)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        window.center()
        model.showWindow = { [weak self] in self?.show() }
        model.hideWindow = { [weak self] in self?.window.orderOut(nil) }
        model.statusChanged = { [weak self] in self?.refreshStatus() }
        model.openPreferences = { [weak self] in self?.preferences() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        refreshStatus()
        model.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        if !model.preferences.hideOnLaunch || CommandLine.arguments.contains("--demo") { show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        Task {
            let success = await model.prepareToQuit()
            if !success { show() }
            quitting = success
            NSApplication.shared.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }
    @objc private func willSleep() {
        Task {
            if !model.demo {
                do { try await model.helper.reset(); model.releaseControl() }
                catch { model.error = error.localizedDescription }
            }
        }
    }
    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func configureMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Macs Fan Control · Swift", action: #selector(about), keyEquivalent: "")
        app.addItem(withTitle: "Preferences…", action: #selector(preferences), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Macs Fan Control · Swift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Macs Fan Control · Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenuItem(); root.submenu = app; main.addItem(root)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc private func about() { show(); model.showAbout = true }
    @objc private func preferences() {
        // Toolbar labels are fixed when built, so rebuild after a language change.
        if preferencesWindow == nil || preferencesLanguage != model.preferences.language { buildPreferences() }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func buildPreferences() {
        preferencesWindow?.close()
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for page in PreferencesPage.allCases {
            let host = NSHostingController(rootView: PreferencesView(model: model, page: page))
            host.sizingOptions = .preferredContentSize
            host.title = page.title(model)
            let item = NSTabViewItem(viewController: host)
            item.label = page.title(model)
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: item.label)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        preferencesWindow = window
        preferencesLanguage = model.preferences.language
    }
    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let policy: NSApplication.ActivationPolicy = model.preferences.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        let display = model.statusDisplay
        // Redraw only when something visible changed; refresh runs every 1.5 s.
        if display != lastStatus || button.effectiveAppearance != lastAppearance {
            lastStatus = display; lastAppearance = button.effectiveAppearance
            button.title = ""
            button.image = StatusItemRenderer.image(display, appearance: button.effectiveAppearance)
            button.imagePosition = .imageOnly
        }
        button.toolTip = "Macs Fan Control · Swift — \(model.activePreset)"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); actions = []
        add(model.text("Show Macs Fan Control", "显示 Macs Fan Control"), to: menu) { self.show() }
        menu.addItem(.separator())
        header(model.text("Fan presets:", "风扇预设："), to: menu)
        for name in [PresetName.automatic, PresetName.fullBlast] + model.presets.map(\.name) {
            let item = add(name, to: menu) { Task { await self.model.applyPreset(name) } }
            item.state = model.activePreset == name ? .on : .off
            item.isEnabled = !model.fans.isEmpty && !model.busy
        }
        menu.addItem(.separator())
        header(model.text("Available fans:", "可用风扇："), to: menu)
        for fan in model.fans {
            let item = NSMenuItem(title: "\(fan.name) — \(fan.current) RPM", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            add(model.text("Change control…", "更改控制…"), to: submenu) { self.show(); self.model.selectedFan = fan }
            add(model.text("Reset to automatic control", "恢复自动控制"), to: submenu) { Task { await self.model.apply([fan.id: .automatic]) } }
            item.submenu = submenu; menu.addItem(item)
        }
        menu.addItem(.separator())
        add(model.text("Preferences…", "偏好设置…"), to: menu) { self.preferences() }
        add(model.text("About…", "关于…"), to: menu) { self.about() }
        add(model.text("Export diagnostics…", "导出诊断信息…"), to: menu) { self.show(); Diagnostics.export(model: self.model) }
        menu.addItem(.separator())
        add(model.text("Quit Macs Fan Control", "退出 Macs Fan Control"), to: menu) { NSApp.terminate(nil) }
    }
    private func header(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
    }
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.tag = actions.count - 1; item.target = self; menu.addItem(item); return item
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

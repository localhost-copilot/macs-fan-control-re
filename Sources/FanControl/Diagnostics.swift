import AppKit
import UniformTypeIdentifiers
import FanCore

@MainActor
enum Diagnostics {
    static func export(model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FanControl-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let info = "Macs Fan Control Swift 1.0.0\nModel: \(Hardware.model)\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nDemo: \(model.demo)\nHelper enabled: \(model.helper.available)\nError: \(model.monitorError ?? "None")\n"
                try info.write(to: temporary.appendingPathComponent("app_info.txt"), atomically: true, encoding: .utf8)
                try model.log.joined(separator: "\n").write(to: temporary.appendingPathComponent("app_log.txt"), atomically: true, encoding: .utf8)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(model.fans).write(to: temporary.appendingPathComponent("fans.json"))
                try encoder.encode(model.sensors).write(to: temporary.appendingPathComponent("sensors.json"))
                var files = ["app_info.txt", "app_log.txt", "fans.json", "sensors.json"]
                if let view = NSApp.windows.first(where: { $0.title.hasPrefix("Macs Fan Control · Swift") })?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: temporary.appendingPathComponent("app_screen.png"))
                        files.append("app_screen.png")
                    }
                }
                let archive = temporary.appendingPathComponent("diagnostics.zip")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = temporary
                process.arguments = ["-q", archive.path] + files
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw FanError.message("Could not create the diagnostics archive.") }
                let data = try Data(contentsOf: archive)
                try data.write(to: destination, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                model.record("Diagnostics exported.")
            } catch { model.error = error.localizedDescription }
        }
    }
}

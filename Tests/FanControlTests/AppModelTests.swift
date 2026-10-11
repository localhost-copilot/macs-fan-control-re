import XCTest
import FanCore
@testable import FanControl

final class AppModelTests: XCTestCase {
    func testElectricalAndUnavailableSensorsRemainVisibleButCannotControlTemperature() async {
        await MainActor.run {
            let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults, demoRequested: true)
            model.sensors = [
                Sensor(id: "Tp01", name: "CPU", celsius: 50),
                Sensor(id: "VP0b", name: "Rail", value: 1.25, quantity: .voltage, source: "SMC"),
                Sensor(id: "PP0b", name: "Power", value: nil, quantity: .power, source: "SMC", issue: "Unavailable")
            ]
            model.preferences.unit = .fahrenheit
            XCTAssertEqual(model.visibleSensors.count, 3)
            XCTAssertEqual(model.controlSensors.map(\.id), ["Tp01"])
            XCTAssertEqual(model.reading(model.sensors[1]), "1.250 V")
            XCTAssertEqual(model.reading(model.sensors[2]), "—")
            XCTAssertEqual(model.reading(model.sensors[0]), "122.0 °F")
        }
    }

    func testInstallerQuotesPathsWithoutShellExpansion() throws {
        let value = "/tmp/a'b $(printf injected) `printf injected`\nwith spaces"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + LocalHelperInstaller.quote(value)]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), value)
    }
    func testInstallerAcceptsPinnedAdHocCodeAndRejectsAReplacedBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mfc-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("a'b helper")
        func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        // Match build-app.sh's single-architecture product. A universal binary
        // has a different cdhash per slice and cannot use one pin for all slices.
        #if arch(arm64)
        let architecture = "arm64e"
        #else
        let architecture = "x86_64"
        #endif
        XCTAssertEqual(try run("/usr/bin/lipo", ["/usr/bin/true", "-thin", architecture, "-output", binary.path]), 0)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.mfc.test.first", binary.path]), 0)
        let requirement = try SigningIdentity.codeRequirement(at: binary)
        let command = LocalHelperInstaller.verificationCommand(path: binary.path, requirement: requirement)
        XCTAssertEqual(try run("/bin/sh", ["-c", command]), 0)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.mfc.test.replaced", binary.path]), 0)
        XCTAssertNotEqual(try run("/bin/sh", ["-c", command]), 0)
    }
    func testRestoringPreferencesDoesNotOverwriteSavedPresets() async throws {
        try await MainActor.run {
            let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = AppModel(defaults: defaults, demoRequested: true)
            original.preferences.language = "zh"
            original.modes = [0: .constant(2400)]
            try original.savePreset(name: "Build")

            let restored = AppModel(defaults: defaults, demoRequested: true)
            XCTAssertEqual(restored.preferences.language, "zh")
            XCTAssertEqual(restored.presets.first?.modes[0], .constant(2400))
            XCTAssertEqual(restored.presets.first?.name, "Build")
            XCTAssertTrue(restored.modes.isEmpty, "Saved presets must never take control automatically on launch")
            XCTAssertEqual(restored.activePreset, "Automatic")

            restored.preferences.decimals = false
            let thirdLaunch = AppModel(defaults: defaults, demoRequested: true)
            XCTAssertEqual(thirdLaunch.presets, original.presets)
        }
    }

    func testRenamingAndDeletingPresetPreservesCurrentControl() async throws {
        try await MainActor.run {
            let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults, demoRequested: true)
            model.modes = [0: .constant(2400)]
            try model.savePreset(name: "Build")
            let id = try XCTUnwrap(model.presets.first?.id)
            try model.savePreset(name: "Compile", replacing: id)
            XCTAssertEqual(model.activePreset, "Compile")
            XCTAssertThrowsError(try model.savePreset(name: "compile"))
            model.deletePreset(try XCTUnwrap(model.presets.first))
            XCTAssertEqual(model.activePreset, "Custom*")
            XCTAssertEqual(model.modes[0], .constant(2400))
            XCTAssertTrue(AppModel(defaults: defaults, demoRequested: true).presets.isEmpty)
        }
    }
}

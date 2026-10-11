import XCTest
import FanCore
@testable import FanControl

final class AppModelTests: XCTestCase {
    @MainActor
    func testMaximumTemperatureControlRestoresAndTracksHottestChannel() async {
        let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AppModel(defaults: defaults, demoRequested: true)
        await original.refresh()
        let changes: [Int: ControlMode] = [0: .sensor(key: "max:cpu", start: 40, maximum: 80), 1: .sensor(key: "max:gpu", start: 35, maximum: 75)]
        let applied = await original.apply(changes)
        XCTAssertTrue(applied)
        let restored = AppModel(defaults: defaults, demoRequested: true)
        await restored.refresh()
        XCTAssertEqual(restored.modes, changes)
        XCTAssertNil(restored.error)
        for family in MaximumTemperature.allCases {
            let maximum = restored.sensors.first { $0.id == family.rawValue }
            let raw = restored.sensors.filter { $0.category == family.category && !$0.id.hasPrefix("max:") }
            XCTAssertEqual(maximum?.celsius, raw.compactMap(\.celsius).max())
            XCTAssertTrue(restored.controlSensors.contains { $0.id == family.rawValue })
        }
    }

    @MainActor
    func testCustomControlSurvivesQuitAndRestoresAfterDiscovery() async throws {
        let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AppModel(defaults: defaults, demoRequested: true)
        await original.refresh()
        let changes: [Int: ControlMode] = [0: .constant(2400), 1: .sensor(key: "Tp01", start: 40, maximum: 80)]
        let applied = await original.apply(changes)
        XCTAssertTrue(applied)
        let quit = await original.prepareToQuit()
        XCTAssertTrue(quit)

        let restored = AppModel(defaults: defaults, demoRequested: true)
        XCTAssertTrue(restored.modes.isEmpty, "Do not claim control before hardware discovery and apply succeed")
        await restored.refresh()
        XCTAssertEqual(restored.modes, changes)
        XCTAssertEqual(restored.activePreset, PresetName.custom)
        XCTAssertNil(restored.error)

        restored.releaseControl()
        await restored.refresh()
        XCTAssertTrue(restored.modes.isEmpty, "A safety release must not trigger another startup restore")
        let relaunched = AppModel(defaults: defaults, demoRequested: true)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.modes, changes, "A safety release must not erase the saved settings")
    }

    @MainActor
    func testAutomaticAndCancelledLiveEditsPersistAcrossLaunches() async {
        let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, demoRequested: true)
        await model.refresh()
        _ = await model.apply([0: .constant(2400)])
        _ = await model.applyLive([0: .constant(3000)])
        // The sheet's Cancel action reapplies its original value.
        _ = await model.applyLive([0: .constant(2400)])
        let restored = AppModel(defaults: defaults, demoRequested: true)
        await restored.refresh()
        XCTAssertEqual(restored.modes[0], .constant(2400))
        let failed = await restored.apply([0: .constant(99999)])
        XCTAssertFalse(failed)
        let afterFailure = AppModel(defaults: defaults, demoRequested: true)
        await afterFailure.refresh()
        XCTAssertEqual(afterFailure.modes[0], .constant(2400))
        await restored.applyPreset(PresetName.automatic)
        let automatic = AppModel(defaults: defaults, demoRequested: true)
        await automatic.refresh()
        XCTAssertTrue(automatic.modes.isEmpty)
        XCTAssertEqual(automatic.activePreset, PresetName.automatic)
    }

    @MainActor
    func testStartupRestoreWaitsForEditsAndDoesNotOverrideNewChoice() async throws {
        let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AppModel(defaults: defaults, demoRequested: true)
        await original.refresh()
        _ = await original.apply([0: .constant(2400)])
        try original.savePreset(name: "Work")
        let restored = AppModel(defaults: defaults, demoRequested: true)
        restored.busy = true
        await restored.refresh()
        XCTAssertTrue(restored.modes.isEmpty)
        restored.busy = false
        await restored.refresh()
        XCTAssertEqual(restored.activePreset, "Work")
        XCTAssertEqual(restored.modes[0], .constant(2400))

        let interrupted = AppModel(defaults: defaults, demoRequested: true)
        interrupted.busy = true
        await interrupted.refresh()
        interrupted.busy = false
        await interrupted.applyPreset(PresetName.automatic)
        await interrupted.refresh()
        XCTAssertTrue(interrupted.modes.isEmpty, "An explicit choice supersedes pending startup control")
    }

    @MainActor
    func testRestoreRejectsUnavailableHardwareWithoutRepeatedAttempts() async {
        let cases: [(Int, ControlMode)] = [(0, .constant(6000)), (0, .sensor(key: "Tbad", start: 40, maximum: 80)), (2, .constant(2400))]
        for (id, mode) in cases {
            let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = AppModel(defaults: defaults, demoRequested: true)
            await original.refresh()
            original.fans[0].maximum = 6500
            original.fans.append(Fan(id: 2, name: "Removed fan", minimum: 1200, current: 1800, maximum: 5800))
            let applied = await original.apply([id: mode])
            XCTAssertTrue(applied)
            let restored = AppModel(defaults: defaults, demoRequested: true)
            await restored.refresh()
            XCTAssertTrue(restored.modes.isEmpty)
            XCTAssertNotNil(restored.error)
            restored.error = nil
            await restored.refresh()
            XCTAssertNil(restored.error, "Failed restoration is attempted only once per launch")
        }
    }

    @MainActor
    func testDemoControlDoesNotBecomeRealControlWhenSwitchingModes() async {
        let suite = "local.macsfancontrol.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, demoRequested: true)
        await model.refresh()
        _ = await model.apply([0: .constant(2400)])
        let restored = AppModel(defaults: defaults, demoRequested: true)
        await restored.switchDemo(false)
        XCTAssertTrue(restored.modes.isEmpty)
        XCTAssertNil(defaults.data(forKey: "lastControl"))
    }

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
            XCTAssertTrue(restored.modes.isEmpty, "Control waits for hardware discovery")
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

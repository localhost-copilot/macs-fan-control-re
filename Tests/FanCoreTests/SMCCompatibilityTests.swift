import XCTest
@testable import FanCore

final class SMCCompatibilityTests: XCTestCase {
    func testCatalogUsesModelInsteadOfBuildArchitecture() {
        let intel = SensorCatalog(model: "MacBookPro16,1")
        XCTAssertNotNil(intel.sensors["TC0P"])
        XCTAssertFalse(SensorCatalog.isAppleSilicon(model: "MacBookPro16,1"))
        for model in ["MacBookPro18,3", "Mac14,9", "Mac15,7", "Mac16,11", "Mac17,2"] {
            let catalog = SensorCatalog(model: model)
            XCTAssertFalse(catalog.groups["CPU Core Average", default: []].isEmpty, model)
            XCTAssertTrue(catalog.sensors.contains { !$0.key.hasPrefix("hid:") && $0.value.category == "gpu" }, model)
            XCTAssertNil(catalog.sensors["TC0P"], model)
        }
    }

    func testMissingAppleSiliconFamiliesUseDiscoveryWithoutIntelMislabeling() {
        for model in ["Macmini9,1", "MacBookPro17,1", "MacBookAir10,1", "iMac21,1", "Mac18,5", "Mac99,1"] {
            let catalog = SensorCatalog(model: model)
            catalog.addDiscoveredSensors(["Tp01", "Te05", "Tg05", "Tf14", "Tm02"])
            XCTAssertEqual(catalog.sensors["Tp01"]?.category, "cpu", model)
            XCTAssertEqual(catalog.sensors["Tg05"]?.category, "gpu", model)
            XCTAssertNil(catalog.sensors["Tf14"], model)
            XCTAssertNil(catalog.sensors["Tm02"], model)
        }
        let intel = SensorCatalog(model: "MacBookPro16,1")
        intel.addDiscoveredSensors(["Tp01", "Te05", "Tg05"])
        XCTAssertNil(intel.groups["CPU Sensors Average (inferred)"])
    }

    func testDirectModesAndBothTargetEncodings() throws {
        for (mode, type) in [("F0Md", "flt "), ("F0md", "flt "), ("F0Md", "fpe2")] {
            let device = SMCFixture(modeKey: mode, targetType: type)
            let smc = device.client()
            try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first))
            XCTAssertEqual(try smc.number("F0Tg"), 2400)
            XCTAssertTrue(try XCTUnwrap(smc.fans().first).manual)
            try smc.setAutomatic(fan: 0)
            XCTAssertEqual(try smc.number(mode), 0)
            XCTAssertFalse(device.writes.contains { $0.0 == "Ftst" })
        }
    }

    func testLegacyMaskPreservesOtherFansIncludingHighBit() throws {
        let device = SMCFixture(modeKey: nil, targetType: "fpe2")
        device.values["FS! "] = ("ui16", [0x80, 0x02])
        let smc = device.client()
        try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first))
        XCTAssertEqual(try smc.number("FS! "), 0x8003)
        try smc.setAutomatic(fan: 0)
        XCTAssertEqual(try smc.number("FS! "), 0x8002)
    }

    func testSystemModeUnlockAndLastFanRecovery() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        device.addSecondFan()
        device.refusalsAfterUnlock = 2
        let smc = device.client()
        let fans = try smc.fans()
        XCTAssertFalse(fans[0].manual, "Firmware mode 3 is system control")
        try smc.setRPM(2400, fan: fans[0])
        try smc.setRPM(2500, fan: fans[1])
        XCTAssertEqual(try smc.number("Ftst"), 1)
        try smc.setAutomatic(fan: 0)
        XCTAssertEqual(try smc.number("Ftst"), 1)
        try smc.setAutomatic(fan: 1)
        XCTAssertEqual(try smc.number("Ftst"), 0)
        XCTAssertEqual(device.waits, 3)
    }

    func testTargetFailureRestoresModeAndUnlock() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        device.rejectedKeys = ["F0Tg"]
        let smc = device.client()
        XCTAssertThrowsError(try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first)))
        XCTAssertEqual(try smc.number("F0Md"), 0)
        XCTAssertEqual(try smc.number("Ftst"), 0)
    }

    func testUnlockRecoveryFailureCanBeRetried() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        let smc = device.client()
        try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first))
        device.rejectedKeys = ["Ftst"]
        XCTAssertThrowsError(try smc.setAutomatic(fan: 0))
        device.rejectedKeys = []
        try smc.setAutomatic(fan: 0)
        XCTAssertEqual(try smc.number("Ftst"), 0)
    }

    func testUnrelatedWriteErrorDoesNotUnlockOrSwitchModeKeys() throws {
        let device = SMCFixture(modeKey: "F0md")
        device.values["F0Md"] = ("ui8 ", [0])
        device.rejectedKeys = ["F0md"]
        let smc = device.client()
        XCTAssertThrowsError(try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first)))
        XCTAssertFalse(device.writes.contains { ["Ftst", "F0Md", "F0Tg"].contains($0.0) })
    }

    func testExistingUnlockIsNotReleasedByThisConnection() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        device.values["Ftst"] = ("flag", [1])
        let smc = device.client()
        try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first))
        try smc.setAutomatic(fan: 0)
        XCTAssertEqual(try smc.number("Ftst"), 1)
        XCTAssertFalse(device.writes.contains { $0.0 == "Ftst" })
    }

    func testMissingUnlockAndIgnoredTargetFailWithoutLeavingManualControl() throws {
        let locked = SMCFixture(modeKey: "F0Md", locked: true)
        locked.values.removeValue(forKey: "Ftst")
        let first = locked.client()
        XCTAssertThrowsError(try first.setRPM(2400, fan: XCTUnwrap(first.fans().first)))
        XCTAssertFalse(locked.writes.contains { $0.0 == "F0Tg" })

        let ignored = SMCFixture(modeKey: "F0Md")
        ignored.ignoredKeys = ["F0Tg"]
        let second = ignored.client()
        XCTAssertThrowsError(try second.setRPM(2400, fan: XCTUnwrap(second.fans().first)))
        XCTAssertEqual(try second.number("F0Md"), 0)
    }

    func testFanlessMachineReturnsEmptyList() throws {
        let device = SMCFixture(modeKey: nil)
        device.values["FNum"] = ("ui8 ", [0])
        XCTAssertTrue(try device.client().fans().isEmpty)
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testUnlockRetryExhaustionReleasesGlobalFlag() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        device.refusalsAfterUnlock = 100
        let smc = device.client()
        XCTAssertThrowsError(try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first)))
        XCTAssertEqual(device.waits, 20)
        XCTAssertEqual(try smc.number("Ftst"), 0)
        XCTAssertFalse(device.writes.contains { $0.0 == "F0Tg" })
    }

    func testUnlockDoesNotInterfereWithAnotherManualFan() throws {
        let device = SMCFixture(modeKey: "F0Md", locked: true)
        device.addSecondFan()
        device.values["F1Md"] = ("ui8 ", [1])
        let smc = device.client()
        XCTAssertThrowsError(try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first)))
        XCTAssertFalse(device.writes.contains { $0.0 == "Ftst" || $0.0.hasPrefix("F1") })
        XCTAssertEqual(try smc.number("F1Md"), 1)
    }

    func testSilentlyIgnoredModeCannotReportSuccessfulControl() throws {
        for mode in ["F0Md", "FS! "] {
            let device = SMCFixture(modeKey: mode == "FS! " ? nil : mode)
            if mode == "FS! " { device.values[mode] = ("ui16", [0, 0]) }
            device.ignoredKeys = [mode]
            let smc = device.client()
            XCTAssertThrowsError(try smc.setRPM(2400, fan: XCTUnwrap(smc.fans().first)))
            XCTAssertFalse(device.writes.contains { $0.0 == "F0Tg" })
        }
    }
}

/// A wire-level SMC device: production code still selects keys, decodes values,
/// encodes writes and owns recovery. No root or real fan writes are involved.
private final class SMCFixture {
    var values: [String: (String, [UInt8])] = [:]
    var writes: [(String, [UInt8])] = []
    var rejectedKeys = Set<String>()
    var ignoredKeys = Set<String>()
    var refusalsAfterUnlock = 0
    var waits = 0
    private let locked: Bool

    init(modeKey: String?, targetType: String = "flt ", locked: Bool = false) {
        self.locked = locked
        values["FNum"] = ("ui8 ", [1])
        for suffix in ["Mn", "Ac", "Mx", "Tg"] {
            let rpm = suffix == "Mx" ? 5800 : 1200
            let bits = Float(rpm).bitPattern
            let bytes = targetType == "fpe2" ? [UInt8((rpm * 4) >> 8), UInt8((rpm * 4) & 255)]
                : (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
            values["F0" + suffix] = (targetType, bytes)
        }
        if let modeKey { values[modeKey] = ("ui8 ", [locked ? 3 : 0]) }
        values["Ftst"] = ("ui8 ", [0])
    }

    func addSecondFan() {
        values["FNum"] = ("ui8 ", [2])
        for (key, value) in Array(values) where key.hasPrefix("F0") {
            values["F1" + key.dropFirst(2)] = value
        }
    }

    func client() -> AppleSMC {
        AppleSMC(exchange: { self.exchange($0) }, waitForMode: { self.waits += 1 })
    }

    private func exchange(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 80)
        let key = String(bytes: input[0..<4].reversed(), encoding: .ascii)!
        guard let (type, bytes) = values[key] else { output[40] = 0x84; return output }
        switch input[42] {
        case 9:
            output[28] = UInt8(bytes.count)
            output.replaceSubrange(32..<36, with: type.utf8.reversed())
        case 5:
            output.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        case 6:
            let payload = Array(input[48..<(48 + bytes.count)])
            writes.append((key, payload))
            if rejectedKeys.contains(key) { output[40] = 0x85; return output }
            if locked, key.hasSuffix("Md"), payload == [1] {
                if values["Ftst"]?.1 != [1] { output[40] = 0x82; return output }
                if refusalsAfterUnlock > 0 { refusalsAfterUnlock -= 1; output[40] = 0x82; return output }
            }
            if !ignoredKeys.contains(key) { values[key] = (type, payload) }
        default: output[40] = 0x85
        }
        return output
    }
}

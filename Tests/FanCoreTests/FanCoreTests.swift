import XCTest
@testable import FanCore

final class FanCoreTests: XCTestCase {
    private let fan = Fan(id: 0, name: "Left", minimum: 1200, current: 2000, maximum: 5800)

    func testSMCDecodingWithSignedTemperatureAndUnalignedFloat() throws {
        XCTAssertEqual(try AppleSMC.decode(type: "sp78", bytes: [0xFF, 0x80]), -0.5)
        XCTAssertEqual(try AppleSMC.decode(type: "sp78", bytes: [0x2A, 0x80]), 42.5)
        XCTAssertEqual(try AppleSMC.decode(type: "fpe2", bytes: [0x1F, 0x40]), 2000)
        XCTAssertEqual(try AppleSMC.decode(type: "flt ", bytes: [0, 0, 0x28, 0x42]), 42)
        XCTAssertThrowsError(try AppleSMC.decode(type: "sp78", bytes: [1]))
        XCTAssertThrowsError(try AppleSMC.decode(type: "oops", bytes: [1, 2]))
    }
    func testInvalidPresetCannotReachHardware() throws {
        let hardware = MockHardware(fans: [fan])
        let session = ControlSession(hardware: hardware)
        XCTAssertThrowsError(try session.apply(ControlRequest(modes: [0: .constant(800)]), now: 0))
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertThrowsError(try session.apply(ControlRequest(modes: [0: .sensor(key: "Tp01", start: 80, maximum: 40)]), now: 0))
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertThrowsError(try session.apply(ControlRequest(modes: [3: .automatic]), now: 0))
    }
    func testElectricalEncodingAndTemperatureIsolation() throws {
        XCTAssertEqual(try AppleSMC.decode(type: "fp2e", bytes: [0x60, 0]), 1.5)
        XCTAssertEqual(try AppleSMC.decode(type: "sp4b", bytes: [0xF4, 0]), -1.5)
        XCTAssertThrowsError(try AppleSMC.decode(type: "sp8f", bytes: [0, 1]))
        let voltage = Sensor(id: "hid:voltage:rail", name: "Rail", value: 12, quantity: .voltage, source: "HID")
        XCTAssertNil(voltage.celsius)
        XCTAssertThrowsError(try ControlMode.sensor(key: "VP0b", start: 40, maximum: 80).validate(for: fan))
        XCTAssertEqual(try JSONDecoder().decode(Sensor.self, from: JSONEncoder().encode(voltage)), voltage)
    }
    func testEnergyDeltaHandlesIdleResetSleepAndUnits() throws {
        var delta = EnergyDelta()
        XCTAssertNil(delta.watts(energy: 1000, unit: "mJ", now: 0))
        XCTAssertEqual(try XCTUnwrap(delta.watts(energy: 5000, unit: "mJ", now: 2)), 2)
        XCTAssertEqual(delta.watts(energy: 5000, unit: "mJ", now: 3), 0)
        XCTAssertNil(delta.watts(energy: 10, unit: "mJ", now: 4))
        XCTAssertNil(delta.watts(energy: 9000, unit: "mJ", now: 30))
        XCTAssertEqual(delta.watts(energy: 10000, unit: "mJ", now: 31), 1)
        XCTAssertNil(delta.watts(energy: 20000, unit: "uJ", now: 32))
        XCTAssertEqual(delta.watts(energy: 1020000, unit: "uJ", now: 33), 1)
        XCTAssertNil(delta.watts(energy: 1020000, unit: "uJ", now: 33))
        XCTAssertNil(delta.watts(energy: 2000000, unit: "unknown", now: 34))
    }
    func testHIDIdentitySeparatesPMUSiblingsAndSurvivesRegistryRenumbering() {
        let first = HIDSensorReader.identity(name: "PMU tdie1", path: "same/path", location: 1414541676, registry: 42, boot: "boot1")
        let second = HIDSensorReader.identity(name: "PMU tdie1", path: "same/path", location: 1414541666, registry: 43, boot: "boot1")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, HIDSensorReader.identity(name: "PMU tdie1", path: "same/path", location: 1414541676, registry: 99, boot: "boot2"))
        XCTAssertNotEqual(HIDSensorReader.identity(name: "unknown", path: "", location: nil, registry: 42, boot: "boot1"), HIDSensorReader.identity(name: "unknown", path: "", location: nil, registry: 42, boot: "boot2"))
    }
    func testTemperatureThresholdsAndRefreshDeadline() throws {
        var controller = TemperatureController()
        XCTAssertEqual(try controller.update(temperature: 35, fan: fan, start: 40, maximum: 80, now: 0), 1200)
        XCTAssertNil(try controller.update(temperature: 35, fan: fan, start: 40, maximum: 80, now: 30))
        XCTAssertEqual(try controller.update(temperature: 35, fan: fan, start: 40, maximum: 80, now: 31), 1200)
        XCTAssertEqual(try controller.update(temperature: 80, fan: fan, start: 40, maximum: 80, now: 32), 5800)
        XCTAssertThrowsError(try controller.update(temperature: nil, fan: fan, start: 40, maximum: 80, now: 33))
    }
    func testControllerRemainsWithinHardwareLimitsAcrossReversals() throws {
        var controller = TemperatureController()
        for (index, temperature) in [30.0, 41, 65, 67, 60, 59, 80, 90, 62, 40, 39].enumerated() {
            _ = try controller.update(temperature: temperature, fan: fan, start: 40, maximum: 80, now: Double(index * 12))
            XCTAssertTrue((fan.minimum...fan.maximum).contains(try XCTUnwrap(controller.target)))
        }
    }
    func testHeartbeatExpiryRestoresOnlyOwnedFans() throws {
        let second = Fan(id: 1, name: "Right", minimum: 1200, current: 2500, maximum: 5800, manual: true)
        let hardware = MockHardware(fans: [fan, second])
        let session = ControlSession(hardware: hardware)
        try session.apply(ControlRequest(modes: [0: .constant(2200)]), now: 10)
        try session.heartbeat(now: 15)
        try session.tick(now: 22)
        XCTAssertTrue(hardware.resets.isEmpty)
        XCTAssertThrowsError(try session.tick(now: 24))
        XCTAssertEqual(hardware.resets, [0])
        try session.tick(now: 50)
        XCTAssertEqual(hardware.resets, [0])
    }
    func testSensorFailureRestoresAutomaticAndStopsWrites() throws {
        let hardware = MockHardware(fans: [fan])
        let session = ControlSession(hardware: hardware)
        try session.apply(ControlRequest(modes: [0: .sensor(key: "Tp01", start: 40, maximum: 80)]), now: 0)
        hardware.sensorMissing = true
        XCTAssertThrowsError(try session.tick(now: 1))
        XCTAssertEqual(hardware.resets, [0])
        let count = hardware.writes.count
        try session.tick(now: 2)
        XCTAssertEqual(hardware.writes.count, count)
    }
    func testLateHeartbeatCannotReviveAnExpiredSession() throws {
        let hardware = MockHardware(fans: [fan])
        let session = ControlSession(hardware: hardware)
        try session.apply(ControlRequest(modes: [0: .constant(2400)]), now: 0)
        let writes = hardware.writes.count
        XCTAssertThrowsError(try session.heartbeat(now: 9))
        XCTAssertEqual(hardware.resets, [0])
        try session.tick(now: 10)
        XCTAssertEqual(hardware.writes.count, writes)
    }
    func testFailedResetIsRetriedWithoutReapplyingManualControl() throws {
        let hardware = MockHardware(fans: [fan])
        let session = ControlSession(hardware: hardware)
        try session.apply(ControlRequest(modes: [0: .constant(2300)]), now: 0)
        hardware.resetFails = true
        XCTAssertThrowsError(try session.reset())
        let count = hardware.writes.count
        XCTAssertThrowsError(try session.tick(now: 1))
        XCTAssertEqual(hardware.writes.count, count)
        hardware.resetFails = false
        try session.tick(now: 2)
        XCTAssertEqual(hardware.resets, [0])
    }
    func testConstantModeSkipsRedundantWritesOnceHardwareHoldsTarget() throws {
        let hardware = MockHardware(fans: [fan])
        let session = ControlSession(hardware: hardware)
        try session.apply(ControlRequest(modes: [0: .constant(2300)]), now: 0)
        let writes = hardware.writes.count
        hardware.availableFans[0].manual = true; hardware.availableFans[0].target = 2300
        try session.tick(now: 1.5)
        XCTAssertEqual(hardware.writes.count, writes)
        hardware.availableFans[0].manual = false
        try session.tick(now: 3)
        XCTAssertEqual(hardware.writes.count, writes + 1)
    }
    func testPartialWriteFailureReleasesClaimedFan() throws {
        let hardware = MockHardware(fans: [fan]); hardware.writeFails = true
        let session = ControlSession(hardware: hardware)
        XCTAssertThrowsError(try session.apply(ControlRequest(modes: [0: .constant(2300)]), now: 0))
        XCTAssertEqual(hardware.resets, [0])
    }
    func testPresetsRoundTripRetainsSensorThresholdsAndFanIDs() throws {
        let preset = Preset(name: "Build", modes: [0: .sensor(key: "Tp01", start: 42.5, maximum: 79), 1: .constant(2200)])
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset)), preset)
    }
    func testModelRangeMatchesDoNotLeakBetweenFamilies() {
        XCTAssertTrue(SensorCatalog.matches("MacBookPro18,3", rule: "MacBookPro18,1+"))
        XCTAssertFalse(SensorCatalog.matches("MacBookPro17,1", rule: "MacBookPro18,1+"))
        XCTAssertFalse(SensorCatalog.matches("MacBookAir18,3", rule: "MacBookPro18,1+"))
        XCTAssertFalse(SensorCatalog.matches("Mac18,5", rule: "MacBookPro18,1+"))
        XCTAssertEqual(SensorCatalog(model: "MacBookPro18,3").fanNames[0], "Left side")
    }
    func testFahrenheitEditingRoundTrip() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.celsius(TemperatureUnit.fahrenheit.display(42.5)), 42.5, accuracy: 0.0001)
    }
    func testDiscoveredCPUAndGPUFallbackIsScopedAndDoesNotGuessAmbiguousKeys() {
        let keys = ["Tp05", "Tp05", "Te07", "Tg08", "TCMb", "TPD0", "TW0P", "TpLong"]
        let catalog = SensorCatalog(model: "Mac18,5")
        catalog.addDiscoveredSensors(keys)
        catalog.addDiscoveredSensors(keys)
        XCTAssertEqual(Set(catalog.groups["CPU Sensors Average (inferred)"] ?? []), ["Tp05", "Te07"])
        XCTAssertEqual(catalog.groups["CPU Sensors Average (inferred)"]?.count, 2)
        XCTAssertEqual(catalog.groups["GPU Sensors Average (inferred)"], ["Tg08"])
        XCTAssertNil(catalog.sensors["TCMb"])
        XCTAssertNil(catalog.sensors["TPD0"])
        XCTAssertNil(catalog.sensors["TpLong"])
        XCTAssertEqual(catalog.sensors["TW0P"]?.name, "Airport Proximity")
        XCTAssertTrue(catalog.hiddenGroupMembers.contains("Tp05"))

        let supported = SensorCatalog(model: "MacBookPro18,3")
        let originalName = supported.sensors["Tp05"]?.name
        supported.addDiscoveredSensors(keys)
        XCTAssertEqual(supported.sensors["Tp05"]?.name, originalName)
        XCTAssertNil(supported.groups["CPU Sensors Average (inferred)"])
    }
}

private final class MockHardware: FanHardware {
    var availableFans: [Fan]
    var writes: [(Int, Int)] = []
    var resets: [Int] = []
    var sensorMissing = false
    var resetFails = false
    var writeFails = false
    init(fans: [Fan]) { availableFans = fans }
    func fans() throws -> [Fan] { availableFans }
    func temperature(_ key: String) throws -> Double {
        if sensorMissing { throw FanError.message("Sensor disconnected") }
        return 55
    }
    func setRPM(_ rpm: Int, fan: Fan) throws {
        if writeFails { throw FanError.message("Write failed") }
        writes.append((fan.id, rpm))
    }
    func setAutomatic(fan: Int) throws {
        if resetFails { throw FanError.message("Reset failed") }
        resets.append(fan)
    }
}

import XCTest
@testable import FanCore

final class FanCoreTests: XCTestCase {
    private let fan = Fan(id: 0, name: "Left", minimum: 1200, current: 2000, maximum: 5800)

    func testCLPCCountersRejectUnverifiedDriversAndOSLayouts() throws {
        let driver = "com.apple.driver.AppleT8152CLPC"
        let supported = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        let reports = try XCTUnwrap(CLPCPower.reports(bundle: driver, version: supported))
        XCTAssertEqual(reports.map(\.id), [0x0000_0010_485d_4bfc, 0x0000_0019_1178_4654, 0x0000_0018_9380_c6bb])
        XCTAssertEqual(reports.map { PowerChannelRole.classify($0.name)?.role }, [.cpu, .gpu, .ane])
        XCTAssertEqual(CLPCPower.reports(bundle: "com.apple.driver.AppleT8112CLPC", version: supported)?.map(\.id),
                       [0x0000_0010_b543_5137, 0x0000_0019_638d_9d52, 0x0000_0018_ea08_9c36], "M2 IDs from macmon's 27.0.1 catalog")
        XCTAssertNil(CLPCPower.reports(bundle: "com.apple.driver.AppleUnknownCLPC", version: supported))
        XCTAssertNil(CLPCPower.reports(bundle: "AppleT8152CLPC", version: supported))
        for version in [
            OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2),
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 2),
            OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)
        ] {
            XCTAssertNil(CLPCPower.reports(bundle: driver, version: version), "Do not reuse opaque counter IDs on unverified OS layouts")
        }
    }

    func testPowerChannelsFollowPowermetricsNames() {
        for name in ["CPU Energy", "CPU_Energy"] { XCTAssertTrue(PowerChannelRole.classify(name)! == (.cpu, false)) }
        for name in ["ECPU", "PCPU1", "MCPU", "EACC_CPU", "PACC0_CPU", "DIE_1_PCPU2", "DIE_0_EACC1_CPU", "pCPUs Energy", "ECPU_NRG", "HACC"] {
            XCTAssertTrue(PowerChannelRole.classify(name)! == (.cpu, true), name)
        }
        for name in ["GPU Energy", "GPU"] { XCTAssertEqual(PowerChannelRole.classify(name)?.role, .gpu) }
        for name in ["ANE", "ANE0", "ANE_1", "ANE0_1"] { XCTAssertEqual(PowerChannelRole.classify(name)?.role, .ane, name) }
        for name in ["DRAM", "DRAM_0", "DRAM0_1"] { XCTAssertEqual(PowerChannelRole.classify(name)?.role, .dram, name) }
        for name in ["PCIe Port 0 Energy", "apciec0 Energy", "GPU SRAM", "CPU", "XCPU", "ECPU Power"] {
            XCTAssertNil(PowerChannelRole.classify(name), name)
        }
    }

    func testPowerChannelsSumClustersOnlyWithoutCPUAggregate() throws {
        func channel(_ name: String, _ value: Double?) -> (name: String, sensor: Sensor) {
            (name, Sensor(id: "ioreport::\(name):0", name: name, value: value, quantity: .power, source: "IOReport", category: "psu"))
        }
        let clusters = PowerChannelRole.present([channel("EACC_CPU", 1), channel("PACC0_CPU", 2), channel("PACC1_CPU", 3),
                                                 channel("GPU Energy", 4), channel("ANE0", 0.5), channel("PCIe Port 0 Energy", 0)])
        let visible = clusters.filter(\.isVisibleByDefault)
        XCTAssertEqual(visible.map(\.name).sorted(), ["ANE Power", "CPU Power", "GPU Power"])
        let cpu = try XCTUnwrap(visible.first { $0.name == "CPU Power" })
        XCTAssertEqual(cpu.value, 6); XCTAssertEqual(cpu.id, "ioreport:sum:CPU Power"); XCTAssertEqual(cpu.source, "IOReport/Sum")
        XCTAssertEqual(clusters.count, 7, "Raw channels remain available but hidden")

        let aggregate = PowerChannelRole.present([channel("CPU Energy", 5), channel("PCPU", 3), channel("ECPU", 1)])
        XCTAssertEqual(aggregate.filter(\.isVisibleByDefault).map(\.id), ["ioreport::CPU Energy:0"], "The aggregate channel wins, as in powermetrics")

        let partial = PowerChannelRole.present([channel("ECPU", 1), channel("PCPU", nil)])
        XCTAssertNil(partial.last?.value); XCTAssertNotNil(partial.last?.issue)
    }

    func testUltraPowerSumsDiesWithoutCountingClustersOrPackageTwice() throws {
        func channel(_ name: String, _ value: Double?) -> (name: String, sensor: Sensor) {
            (name, Sensor(id: name, name: name, value: value, quantity: .power, source: "IOReport"))
        }
        let dies = [channel("DIE_0_CPU Energy", 4), channel("DIE_1_CPU Energy", 6)]
        let clusters = [channel("DIE_0_ECPU", 1), channel("DIE_1_PCPU", 2)]
        let cpu = PowerChannelRole.present(dies + clusters).filter(\.isVisibleByDefault)
        XCTAssertEqual(cpu.count, 1)
        XCTAssertEqual(cpu.first?.name, "CPU Power")
        XCTAssertEqual(cpu.first?.value, 10)

        let package = PowerChannelRole.present(dies + clusters + [channel("CPU Energy", 12)])
        XCTAssertEqual(package.filter(\.isVisibleByDefault).map(\.value), [12])
        let partial = PowerChannelRole.present([dies[0], channel("DIE_1_CPU Energy", nil)] + clusters)
        XCTAssertNil(try XCTUnwrap(partial.first { $0.isVisibleByDefault }).value,
                     "A missing die must not produce a misleading partial CPU total")
    }

    func testPowerPrefersValidCLPCAndPreservesIdentity() throws {
        var primary = Sensor(id: "ioreport::GPU Energy:0", name: "GPU Power", value: nil,
                             quantity: .power, source: "IOReport", issue: "Sampling failed")
        var fallback = Sensor(id: "ioreport:Energy Counters:GPU Energy:0", name: "GPU Power", value: 3,
                              quantity: .power, source: "IOReport/CLPC")
        let raw = Sensor(id: "raw", name: "Unclassified rail", value: 1, quantity: .power, source: "IOReport")
        func merged() throws -> Sensor {
            let result = PowerChannelRole.mergeSources(energyModel: [primary, raw], clpc: [fallback])
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.last, raw)
            let gpu = try XCTUnwrap(result.first)
            XCTAssertEqual(gpu.id, primary.id, "Saved menu selections must survive switching sources")
            return gpu
        }
        let recovered = try merged()
        XCTAssertEqual(recovered.value, 3)
        XCTAssertEqual(recovered.source, fallback.source)
        XCTAssertNil(recovered.issue)
        for invalid in [Double.nan, .infinity, -1] {
            primary.value = invalid
            XCTAssertEqual(try merged().value, 3)
        }
        primary.value = 0; primary.issue = nil
        XCTAssertEqual(try merged().value, 3, "A frozen Energy Model counter reads as zero; CLPC wins")
        primary.value = 5
        XCTAssertEqual(try merged().value, 3, "Valid CLPC wins over a valid Energy Model reading")
        fallback.value = nil
        XCTAssertEqual(try merged(), primary, "Use Energy Model when CLPC is unreadable")
        primary.value = nil; primary.issue = "Sampling failed"
        XCTAssertEqual(try merged(), primary, "Retain the failure when neither source is readable")
        fallback.value = 0
        XCTAssertEqual(try merged().value, 0, "CLPC idle zero is also valid")

        primary.name = "ANE Power"; fallback.name = "ANE Power"
        XCTAssertFalse(try merged().isVisibleByDefault, "Unverified CLPC ANE remains hidden during fallback")
        XCTAssertFalse(try XCTUnwrap(PowerChannelRole.mergeSources(energyModel: [], clpc: [fallback]).first).isVisibleByDefault)
    }

    func testMaximumTemperatureUsesCurrentRawReadingsAndSeparatesFamilies() throws {
        var readings = [
            Sensor(id: "Tp01", name: "CPU 1", celsius: 45, category: "cpu"),
            Sensor(id: "hid:cpu2", name: "CPU 2", celsius: 62, category: "cpu"),
            Sensor(id: "Tg01", name: "GPU", celsius: 81, category: "gpu"),
            Sensor(id: "avg:cpu", name: "Old average", celsius: 95, category: "cpu"),
            Sensor(id: "max:cpu", name: "Old maximum", celsius: 99, category: "cpu"),
            Sensor(id: "VC00", name: "Voltage", value: 100, quantity: .voltage, source: "SMC", category: "cpu")
        ]
        let maximum = try XCTUnwrap(MaximumTemperature.cpu.sensor(from: readings))
        XCTAssertEqual(maximum.celsius, 62)
        XCTAssertEqual(MaximumTemperature.gpu.sensor(from: readings)?.celsius, 81)
        readings[1].value = 30
        XCTAssertEqual(MaximumTemperature.cpu.sensor(from: readings)?.celsius, 45, "The maximum falls when the hottest channel cools")
        let mode = ControlMode.sensor(key: maximum.id, start: 40, maximum: 80)
        XCTAssertNoThrow(try mode.validate(for: fan))
        let preset = Preset(name: "Hottest CPU", modes: [0: mode])
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset)), preset)
        XCTAssertThrowsError(try ControlMode.sensor(key: "max:unknown", start: 40, maximum: 80).validate(for: fan))
    }

    func testMaximumTemperatureHandlesPartialAndTotalSensorLoss() throws {
        var readings = [
            Sensor(id: "Tp01", name: "CPU 1", celsius: nil, category: "cpu"),
            Sensor(id: "Tp02", name: "CPU 2", celsius: .nan, category: "cpu"),
            Sensor(id: "Tp03", name: "CPU 3", celsius: .infinity, category: "cpu"),
            Sensor(id: "Tp04", name: "CPU 4", celsius: 51, category: "cpu")
        ]
        XCTAssertEqual(MaximumTemperature.cpu.sensor(from: readings)?.celsius, 51)
        readings[3].value = nil
        let unavailable = try XCTUnwrap(MaximumTemperature.cpu.sensor(from: readings))
        XCTAssertNil(unavailable.celsius)
        XCTAssertNotNil(unavailable.issue)
        XCTAssertNil(MaximumTemperature.gpu.sensor(from: readings), "Do not invent a family with no known channels")
    }

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
        let catalog = SensorCatalog(model: "Mac99,1")
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
    func testMac18_5UsesLoadVerifiedClusterFamilies() {
        let catalog = SensorCatalog(model: "Mac18,5")
        catalog.addDiscoveredSensors(["Tp05", "Te07", "Tg01", "Tp99"])
        XCTAssertEqual(catalog.sensors["Tp05"]?.category, "cpu")
        XCTAssertEqual(catalog.sensors["Te07"]?.category, "cpu")
        XCTAssertEqual(catalog.sensors["Tg01"]?.category, "gpu")
        XCTAssertEqual(catalog.groups["CPU Performance Cluster Average"]?.count, 21)
        XCTAssertEqual(catalog.groups["CPU Efficiency Cluster Average"]?.count, 9)
        XCTAssertEqual(catalog.groups["GPU Average"]?.count, 18)
        XCTAssertNil(catalog.sensors["Tp99"], "Mapped families do not add unverified keys")
        XCTAssertFalse(catalog.sensors.values.contains { $0.name.hasSuffix("(inferred)") })
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

import Foundation
import IOKit

/// macOS 27 no longer enumerates these AppleCLPC energy counters in Energy Model,
/// and powermetrics has no CLPC path. Report IDs are `(index << 32) | key`, with
/// keys extracted from Apple firmware by macmon's CLPC discovery:
/// https://github.com/vladkens/macmon/blob/main/docs/clpc-discovery.md
/// Restrict them to the OS releases whose layouts were extracted.
enum CLPCPower {
    private static let keys: [String: (cpu: UInt32, gpu: UInt32, ane: UInt32)] = [
        "AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8),
        "AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
        "AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f),
        "AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
        "AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38),
        "AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
        "AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25),
        "AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),
        "AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59),
        "AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
        "AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81),
        "AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
        "AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f),
        "AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
        "AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b),
        "AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
        "AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb)
    ]

    /// Energy Model-compatible channel names so PowerChannelRole classifies them.
    static func reports(bundle: String, version: OperatingSystemVersion) -> [(id: UInt64, name: String)]? {
        let prefix = "com.apple.driver."
        guard bundle.hasPrefix(prefix), let key = keys[String(bundle.dropFirst(prefix.count))],
              version.majorVersion == 27, version.minorVersion == 0,
              (0...1).contains(version.patchVersion) else { return nil }
        func id(_ index: UInt64, _ key: UInt32) -> UInt64 { index << 32 | UInt64(key) }
        return [(id(16, key.cpu), "CPU Energy"), (id(25, key.gpu), "GPU Energy"), (id(24, key.ane), "ANE")]
    }

    static func channels() -> CFMutableDictionary? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let reports = reports(bundle: bundle, version: ProcessInfo.processInfo.operatingSystemVersion) else { return nil }
        var driver: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS else { return nil }

        // IOReportTypes: scalar integer, power category, one element; nanojoules.
        // Channel dictionaries must be mutable because IOReport caches metadata in them.
        let channels: [NSMutableDictionary] = reports.map { report in [
            "DriverID": NSNumber(value: driver), "DriverName": "AppleCLPC",
            "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
            "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: (UInt64(3) << 56) | (118 << 32))],
            "LegendChannel": [NSNumber(value: report.id), NSNumber(value: UInt64(1 | (2 << 16) | (1 << 32))), report.name]
        ] }
        let dictionary: NSDictionary = ["IOReportChannels": channels]
        return CFDictionaryCreateMutableCopy(nil, 0, dictionary as CFDictionary)
    }
}

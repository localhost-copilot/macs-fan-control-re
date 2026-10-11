import Foundation
import IOKit

/// macOS 27 no longer enumerates this CPU energy counter in Energy Model.
/// The report identity and nJ unit are documented in macmon's CLPC discovery:
/// https://github.com/vladkens/macmon/blob/main/docs/clpc-discovery.md
/// Restrict this fallback to the driver and OS releases verified for this app.
enum CLPCCPUPower {
    static func reportID(bundle: String, version: OperatingSystemVersion) -> UInt64? {
        guard bundle == "com.apple.driver.AppleT8152CLPC",
              version.majorVersion == 27, version.minorVersion == 0,
              (0...1).contains(version.patchVersion) else { return nil }
        return 0x0000_0010_485d_4bfc
    }

    static func channels() -> CFMutableDictionary? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let report = reportID(bundle: bundle, version: ProcessInfo.processInfo.operatingSystemVersion) else { return nil }
        var driver: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS else { return nil }

        // IOReportTypes: scalar integer, power category, one element; nanojoules.
        // Channel dictionaries must be mutable because IOReport caches metadata in them.
        let channel: NSMutableDictionary = [
            "DriverID": NSNumber(value: driver), "DriverName": "AppleCLPC",
            "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
            "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: (UInt64(3) << 56) | (118 << 32))],
            "LegendChannel": [NSNumber(value: report), NSNumber(value: UInt64(1 | (2 << 16) | (1 << 32))), "CPU Energy"]
        ]
        let channels: NSDictionary = ["IOReportChannels": [channel]]
        return CFDictionaryCreateMutableCopy(nil, 0, channels as CFDictionary)
    }
}

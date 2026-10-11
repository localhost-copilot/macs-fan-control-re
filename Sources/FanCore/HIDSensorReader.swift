import Foundation
import IOKit
import CryptoKit

/// Optional private IOKit entry points, resolved at runtime. Each usage gets its
/// own client so reading electrical channels cannot change temperature matching.
public final class HIDSensorReader {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias RegistryID = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double
    private let clients: [(CFTypeRef, SensorQuantity, Int64)]
    private let copyServices: Services
    private let copyProperty: Property
    private let registryID: RegistryID
    private let copyEvent: Event
    private let floatValue: FloatValue
    private var lastReadings: [Sensor] = []
    // Registry entries are stable while a service exists; resolve each identity once.
    private var identities: [UInt64: (id: String, backingSMCKey: String?)] = [:]
    private var values: [UInt64: Double?] = [:]
    private static let bootID: String = {
        var time = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return UUID().uuidString }
        return "\(time.tv_sec):\(time.tv_usec)"
    }()
    // Keep the framework loaded for the lifetime of all CF clients/events.
    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    public init?() {
        guard let library = Self.library else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
              let match = symbol("IOHIDEventSystemClientSetMatching", as: Match.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", as: Services.self),
              let property = symbol("IOHIDServiceClientCopyProperty", as: Property.self),
              let registryID = symbol("IOHIDServiceClientGetRegistryID", as: RegistryID.self),
              let event = symbol("IOHIDServiceClientCopyEvent", as: Event.self),
              let value = symbol("IOHIDEventGetFloatValue", as: FloatValue.self) else { return nil }
        copyServices = services; copyProperty = property; self.registryID = registryID
        copyEvent = event; floatValue = value
        let usages: [(Int, Int, SensorQuantity, Int64)] = [
            (0xFF00, 5, .temperature, 15), (0xFF08, 2, .current, 25), (0xFF08, 3, .voltage, 25)
        ]
        clients = usages.compactMap { page, usage, quantity, event in
            guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
            _ = match(client, ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary)
            return (client, quantity, event)
        }
    }

    /// Services whose product name fails `refresh` keep their previous value;
    /// each event copy is a round trip to the HID event system.
    public func readings(refresh: (String) -> Bool = { _ in true }) -> [Sensor] {
        var result: [Sensor] = []
        for (client, quantity, eventType) in clients {
            guard let services = copyServices(client)?.takeRetainedValue() else { continue }
            for index in 0..<CFArrayGetCount(services) {
                let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: CFTypeRef.self)
                let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "Unnamed HID sensor"
                guard let number = registryID(service)?.takeUnretainedValue() as? NSNumber else { continue }
                let registry = number.uint64Value
                let resolved = identities[registry] ?? resolve(service, name: name, registry: registry, quantity: quantity)
                identities[registry] = resolved
                let id = resolved.id
                var value: Double?
                var rawValue: Double?
                if !refresh(name), let cached = values[registry] {
                    rawValue = cached
                    if let raw = cached, quantity == .temperature ? (raw > 0 && raw < 127) : (raw >= 0 && raw < 300) { value = raw }
                } else if let event = copyEvent(service, eventType, 0, 0)?.takeRetainedValue() {
                    let raw = floatValue(event, Int32(eventType << 16))
                    if raw.isFinite {
                        rawValue = raw
                        if quantity == .temperature ? (raw > 0 && raw < 127) : (raw >= 0 && raw < 300) { value = raw }
                    }
                }
                values[registry] = rawValue
                var sensor = Sensor(id: id, name: name, value: value, quantity: quantity, source: "HID", issue: value == nil ? "No valid HID measurement (registry \(registry)); raw value: \(rawValue.map(String.init(describing:)) ?? "unavailable")." : nil)
                sensor.rawValue = rawValue
                sensor.backingSMCKey = resolved.backingSMCKey
                result.append(sensor)
            }
        }
        // Preserve old product-name preset keys only when they resolve uniquely.
        let counts = Dictionary(grouping: result, by: { $0.name }).mapValues(\.count)
        var readings = result.map { sensor in
            var item = sensor
            if counts[sensor.name] == 1, sensor.quantity == .temperature {
                item = Sensor(id: "hid:" + sensor.name, name: sensor.name, value: sensor.value, quantity: sensor.quantity, source: sensor.source, issue: sensor.issue)
                item.backingSMCKey = sensor.backingSMCKey; item.rawValue = sensor.rawValue
            } else if counts[sensor.name, default: 0] > 1 {
                item.name += " [\(sensor.id.suffix(6))]"
            }
            return item
        }
        let found = Set(readings.map(\.id))
        readings += lastReadings.filter { !found.contains($0.id) }.map { sensor in
            var item = sensor; item.value = nil; item.rawValue = nil
            item.issue = "HID service is no longer available."; return item
        }
        lastReadings = readings
        return readings
    }
    private func resolve(_ service: CFTypeRef, name: String, registry: UInt64, quantity: SensorQuantity) -> (id: String, backingSMCKey: String?) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registry))
        var path = [CChar](repeating: 0, count: 4096)
        let hasPath = entry != 0 && IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
        if entry != 0 { IOObjectRelease(entry) }
        let location = copyProperty(service, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber
        // PMU siblings can share both their name and registry path.
        // LocationID identifies the backing SMC key on Apple Silicon.
        let identity = Self.identity(name: name, path: hasPath ? String(cString: path) : "", location: location?.uint32Value, registry: registry, boot: Self.bootID)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var backingSMCKey: String?
        if let location {
            let bits = location.uint32Value
            let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
            if bytes.allSatisfy({ (32...126).contains($0) }), let key = String(bytes: bytes, encoding: .ascii),
               key.first == (quantity == .temperature ? "T" : quantity == .voltage ? "V" : "I") { backingSMCKey = key }
        }
        return ("hid:\(quantity.rawValue):\(digest)", backingSMCKey)
    }
    static func identity(name: String, path: String, location: UInt32?, registry: UInt64, boot: String) -> String {
        if let location, location != 0 { return "\(path)|\(name)|\(location)" }
        // Never reuse a registry-only preset for a different sensor after reboot.
        return "\(boot)|\(registry)|\(name)"
    }
}

import Foundation

public final class SensorCatalog: NSObject, XMLParserDelegate {
    public private(set) var sensors: [String: (name: String, category: String)] = [:]
    public private(set) var fanNames: [Int: String] = [:]
    public private(set) var groups: [String: [String]] = [:]
    public private(set) var hiddenGroupMembers: Set<String> = []
    private var model: String
    private var matches = false
    private var key: String?
    private var category = "temperature"
    private var text = ""
    private var fanIndex: Int?
    private var group: String?
    private var hideGroupMembers = false

    private static let resources: Bundle? = {
        // SwiftPM's generated accessor can search the build machine's absolute
        // path. Packaged app and helper executables share Contents/Resources.
        if let directory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let contents = directory.deletingLastPathComponent()
            if directory.lastPathComponent == "MacOS", contents.deletingLastPathComponent().pathExtension == "app" {
                return Bundle(url: contents.appendingPathComponent("Resources/MacsFanControlSwift_FanCore.bundle"))
            }
        }
        return Bundle.module
    }()

    public init(model: String = Hardware.model) {
        self.model = model
        super.init()
        guard let resources = Self.resources else {
            fputs("Sensor catalog resources are missing from the application bundle.\n", stderr)
            return
        }
        if let url = resources.url(forResource: "idSwapRules", withExtension: "xml", subdirectory: "Resources"), let parser = XMLParser(contentsOf: url) {
            parser.delegate = self; _ = parser.parse()
        }
        let database = Self.isAppleSilicon(model: model, nativeArm: model == Hardware.model && Hardware.isAppleSilicon)
            ? "smcSensors-appleSilicon" : "smcSensors-intel"
        for file in [database, "fanInfo", "iokitSensors"] {
            if let url = resources.url(forResource: file, withExtension: "xml", subdirectory: "Resources"),
               let parser = XMLParser(contentsOf: url) {
                parser.delegate = self
                _ = parser.parse()
            }
        }
    }
    /// Fill missing CPU/GPU families on Apple Silicon without claiming core identities.
    /// Existing model-specific SMC groups take precedence; HID may be unavailable.
    public func addDiscoveredSensors(_ keys: [String]) {
        guard Self.isAppleSilicon(model: model, nativeArm: model == Hardware.model && Hardware.isAppleSilicon) else { return }
        let mappedCategories = Set(sensors.filter {
            !$0.key.hasPrefix("hid:") && !$0.value.name.hasSuffix("(inferred)")
        }.map { $0.value.category })
        for key in Set(keys).sorted() where key.utf8.count == 4 && sensors[key] == nil {
            let family: String
            if key.hasPrefix("Tp") || key.hasPrefix("Te") { family = "CPU" }
            else if key.hasPrefix("Tg") { family = "GPU" }
            else { continue }
            guard !mappedCategories.contains(family.lowercased()) else { continue }
            sensors[key] = ("\(family) Sensor \(key) (inferred)", family.lowercased())
            groups["\(family) Sensors Average (inferred)", default: []].append(key)
            hiddenGroupMembers.insert(key)
        }
    }

    /// The host CPU is authoritative for this machine (including Rosetta and
    /// unknown families such as VirtualMac); the model table covers other models.
    static func isAppleSilicon(model: String, nativeArm: Bool = false) -> Bool {
        if nativeArm { return true }
        let family = String(model.prefix { !$0.isNumber })
        guard let major = Int(model.dropFirst(family.count).split(separator: ",").first ?? "") else { return false }
        switch family {
        case "Mac", "MacStudio", "MacBookNeo": return true
        case "MacBookPro": return major >= 17
        case "MacBookAir": return major >= 10
        case "Macmini": return major >= 9
        case "iMac": return major >= 21
        case "MacPro": return major >= 8
        default: return false
        }
    }

    public static func matches(_ model: String, rule: String) -> Bool {
        if rule == "all" || rule == model { return true }
        guard rule.hasSuffix("+") else { return false }
        let base = String(rule.dropLast())
        let family = base.prefix { !$0.isNumber }
        guard model.hasPrefix(family) else { return false }
        let lhs = model.dropFirst(family.count).split(separator: ",").compactMap { Int($0) }
        let rhs = base.dropFirst(family.count).split(separator: ",").compactMap { Int($0) }
        guard lhs.count == 2, rhs.count == 2 else { return false }
        return lhs[0] > rhs[0] || (lhs[0] == rhs[0] && lhs[1] >= rhs[1])
    }
    public func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "swap", attributes["from"] == model, let replacement = attributes["to"] { model = replacement }
        if element == "modelMatch" {
            matches = (attributes["models"] ?? "").split(separator: ";").contains { Self.matches(model, rule: String($0)) }
        }
        if matches && element == "group" { group = attributes["name"]; hideGroupMembers = attributes["hideSensors"] != "0" }
        if matches && (element == "smc" || element == "iokit"), let name = attributes["name"] {
            key = (element == "iokit" ? "hid:" : "") + name
            category = attributes["type"] ?? "temperature"; text = ""
            if let group, let key { groups[group, default: []].append(key) }
            if group != nil && hideGroupMembers, let key { hiddenGroupMembers.insert(key) }
        }
        if matches && element.hasPrefix("fan"), let index = Int(element.dropFirst(3)) { fanIndex = index; text = "" }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    public func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "smc" || element == "iokit", let key { sensors[key] = (text.trimmingCharacters(in: .whitespacesAndNewlines), category); self.key = nil }
        if let index = fanIndex, element == "fan\(index)" { fanNames[index] = text.trimmingCharacters(in: .whitespacesAndNewlines); fanIndex = nil }
        if element == "modelMatch" { matches = false }
        if element == "group" { group = nil; hideGroupMembers = false }
    }
}

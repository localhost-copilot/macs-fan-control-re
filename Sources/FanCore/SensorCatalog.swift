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

    public init(model: String = Hardware.model) {
        self.model = model
        super.init()
        if let url = Bundle.module.url(forResource: "idSwapRules", withExtension: "xml", subdirectory: "Resources"), let parser = XMLParser(contentsOf: url) {
            parser.delegate = self; _ = parser.parse()
        }
        #if arch(arm64)
        let database = "smcSensors-appleSilicon"
        #else
        let database = "smcSensors-intel"
        #endif
        for file in [database, "fanInfo", "iokitSensors"] {
            if let url = Bundle.module.url(forResource: file, withExtension: "xml", subdirectory: "Resources"),
               let parser = XMLParser(contentsOf: url) {
                parser.delegate = self
                _ = parser.parse()
            }
        }
    }
    /// Mac18,5 exposes these families, but individual core assignments are not
    /// established. Keep the inference visible and never overwrite model mappings.
    public func addDiscoveredSensors(_ keys: [String]) {
        guard model == "Mac18,5" else { return }
        for key in Set(keys).sorted() where key.utf8.count == 4 && sensors[key] == nil {
            let family: String
            if key.hasPrefix("Tp") || key.hasPrefix("Te") { family = "CPU" }
            else if key.hasPrefix("Tg") { family = "GPU" }
            else { continue }
            sensors[key] = ("\(family) Sensor \(key) (inferred)", family.lowercased())
            groups["\(family) Sensors Average (inferred)", default: []].append(key)
            hiddenGroupMembers.insert(key)
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

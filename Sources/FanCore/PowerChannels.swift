import Foundation

/// Energy Model channel roles recovered from `/usr/bin/powermetrics` (macOS 27.0.1,
/// `cpu_power_arm.m`): its IOReportPrune callbacks keep these names and report
/// CPU power as either the aggregate channel or the sum of per-cluster channels.
enum PowerChannelRole: String, CaseIterable {
    case cpu = "CPU", gpu = "GPU", ane = "ANE", dram = "DRAM"

    private static let clusterNames: Set<String> = [
        "eCPUs Energy", "mCPUs Energy", "pCPUs Energy", "ECPU Energy", "MCPU Energy", "PCPU Energy",
        "ECPU_NRG", "MCPU_NRG", "PCPU_NRG", "MPCPU_NRG", "EMCPU_NRG", "EACC", "MACC", "PACC", "HACC"
    ]
    private static let cluster = try! NSRegularExpression(pattern: "^(DIE_[0-9]+_)?(E|M|P|MP|EM)(CPU[0-9]*|ACC[0-9]*_CPU)$")
    private static let indexed = try! NSRegularExpression(pattern: "^(ANE|DRAM)[0-9]*(_[0-9]+)?$")
    private static let dieTotal = try! NSRegularExpression(pattern: "^DIE_[0-9]+_CPU Energy$")

    /// Returns the role and whether the channel is one cluster of a CPU total.
    static func classify(_ name: String) -> (role: PowerChannelRole, isCluster: Bool)? {
        func matches(_ regex: NSRegularExpression) -> Bool {
            regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        switch name {
        case "CPU Energy", "CPU_Energy": return (.cpu, false)
        case "GPU Energy", "GPU": return (.gpu, false)
        default: break
        }
        if matches(dieTotal) { return (.cpu, false) }
        if clusterNames.contains(name) || matches(cluster) { return (.cpu, true) }
        guard matches(indexed) else { return nil }
        return name.hasPrefix("ANE") ? (.ane, false) : (.dram, false)
    }

    /// Prefer package CPU totals, then die totals, then clusters; never sum
    /// overlapping representations. Unclassified rails stay raw.
    static func present(_ channels: [(name: String, sensor: Sensor)]) -> [Sensor] {
        var result = channels.map { item -> Sensor in
            var sensor = item.sensor; sensor.isVisibleByDefault = false; return sensor
        }
        var members: [PowerChannelRole: [Int]] = [:]
        let hasCPUTotal = channels.contains { classify($0.name).map { $0.role == .cpu && !$0.isCluster } ?? false }
        let hasPackageTotal = channels.contains { $0.name == "CPU Energy" || $0.name == "CPU_Energy" }
        for (index, item) in channels.enumerated() {
            guard let match = classify(item.name), !(match.isCluster && hasCPUTotal) else { continue }
            // Ultra die totals replace cluster counters, but must not be added
            // to a package total when both representations are exposed.
            if hasPackageTotal && item.name.hasPrefix("DIE_") && match.role == .cpu { continue }
            members[match.role, default: []].append(index)
        }
        for role in allCases {
            guard let indices = members[role], let first = indices.first else { continue }
            let name = role.rawValue + " Power"
            if indices.count == 1 {
                result[first].name = name; result[first].isVisibleByDefault = true; continue
            }
            let values = indices.compactMap { result[$0].value }
            let complete = values.count == indices.count
            let parts = indices.map { channels[$0].name }.joined(separator: " + ")
            result.append(Sensor(id: "ioreport:sum:" + name, name: name, value: complete ? values.reduce(0, +) : nil, quantity: .power,
                                 source: result[first].source + "/Sum", issue: complete ? nil : "Waiting for every summed channel: \(parts).", category: "psu"))
        }
        return result
    }

    /// On macOS 27, Energy Model CPU/ANE counters can stay visible but stop
    /// updating without Apple's `com.apple.private.pmgr.nrg.reporting`
    /// entitlement, which reads as a valid idle zero. Prefer valid CLPC values
    /// (including idle zero), as macmon does, but keep the Energy Model
    /// identity so saved menu selections survive switching sources.
    static func mergeSources(energyModel: [Sensor], clpc: [Sensor]) -> [Sensor] {
        func valid(_ sensor: Sensor) -> Bool {
            sensor.value.map { $0.isFinite && $0 >= 0 } ?? false
        }
        let reported = Set(energyModel.filter(\.isVisibleByDefault).map(\.name))
        var result = energyModel.map { sensor in
            guard sensor.isVisibleByDefault,
                  let fallback = clpc.first(where: { $0.name == sensor.name && valid($0) }) else { return sensor }
            var item = sensor
            item.value = fallback.value; item.source = fallback.source; item.issue = fallback.issue
            if item.name == "ANE Power" { item.isVisibleByDefault = false }
            return item
        }
        result += clpc.filter { !reported.contains($0.name) }.map { sensor in
            // CLPC ANE has not been verified under load; keep it available as raw data.
            var item = sensor
            if item.name == "ANE Power" { item.isVisibleByDefault = false }
            return item
        }
        return result
    }
}

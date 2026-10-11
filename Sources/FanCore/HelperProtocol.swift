import Foundation
import Security

public let helperServiceName = "local.macsfancontrol.swift.helper"
public let appBundleIdentifier = "local.macsfancontrol.swift"

@objc public protocol FanHelperProtocol {
    func apply(_ data: Data, reply: @escaping (String?) -> Void)
    func heartbeat(reply: @escaping (String?) -> Void)
    func reset(reply: @escaping (String?) -> Void)
}

public struct ControlRequest: Codable {
    public let modes: [Int: ControlMode]
    public init(modes: [Int: ControlMode]) { self.modes = modes }
}

public enum SigningIdentity {
    /// Pin an ad-hoc build to its actual signed code, never just a bundle ID/path.
    public static func codeRequirement(at url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw FanError.message("Code signature validation failed: \(url.lastPathComponent). Rebuild the app before installing its helper.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw FanError.message("Cannot obtain the build’s code signature hash.")
        }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

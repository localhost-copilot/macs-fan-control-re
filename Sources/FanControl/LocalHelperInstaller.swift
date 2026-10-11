import AppKit
import FanCore

/// Development builds have no Apple team certificate. An administrator installs
/// a root-owned copy and pins both ends of XPC to this exact app/helper build.
struct LocalHelperInstaller {
    static let installedApp = "/Library/PrivilegedHelperTools/" + helperServiceName + ".app"
    static let plistPath = "/Library/LaunchDaemons/" + helperServiceName + ".plist"
    let app: URL
    let clientRequirement: String
    let helperRequirement: String

    init(app: URL = Bundle.main.bundleURL) throws {
        guard app.pathExtension == "app" else { throw FanError.message("Run the packaged .app to enable fan control.") }
        self.app = app
        clientRequirement = try SigningIdentity.codeRequirement(at: app)
        helperRequirement = try SigningIdentity.codeRequirement(at: app.appendingPathComponent("Contents/MacOS/FanHelper"))
    }

    var installed: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: Self.plistPath),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o022 == 0,
              let data = FileManager.default.contents(atPath: Self.plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == [Self.installedApp + "/Contents/MacOS/FanHelper", "--client-requirement", clientRequirement],
              let actual = try? SigningIdentity.codeRequirement(at: URL(fileURLWithPath: Self.installedApp + "/Contents/MacOS/FanHelper")) else { return false }
        return actual == helperRequirement
    }

    func install() async throws {
        let plist: [String: Any] = [
            "Label": helperServiceName,
            "ProgramArguments": [Self.installedApp + "/Contents/MacOS/FanHelper", "--client-requirement", clientRequirement],
            "MachServices": [helperServiceName: true], "RunAtLoad": true,
            "KeepAlive": true, "ProcessType": "Interactive", "ExitTimeOut": 15
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // Verify after copying into root-owned staging. Verifying a user-writable
        // source before copying would permit a substitution during authorization.
        let command = """
        set -eu
        /bin/mkdir -p /Library/PrivilegedHelperTools
        mfc_stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.mfc-swift.XXXXXX)
        trap '/bin/rm -rf "$mfc_stage"' EXIT
        /usr/bin/ditto \(Self.quote(app.path)) "$mfc_stage/helper.app"
        /usr/sbin/chown -R root:wheel "$mfc_stage/helper.app"
        /bin/chmod -RN "$mfc_stage/helper.app"
        /bin/chmod -R go-w "$mfc_stage/helper.app"
        cd "$mfc_stage"
        \(Self.verificationCommand(path: "helper.app", requirement: clientRequirement))
        \(Self.verificationCommand(path: "helper.app/Contents/MacOS/FanHelper", requirement: helperRequirement))
        /bin/echo \(Self.quote(data.base64EncodedString())) | /usr/bin/base64 -D > "$mfc_stage/helper.plist"
        /bin/chmod 644 "$mfc_stage/helper.plist"
        if /bin/launchctl print system/\(helperServiceName) >/dev/null 2>&1; then
            /bin/launchctl bootout system/\(helperServiceName)
        fi
        /bin/rm -rf \(Self.quote(Self.installedApp))
        /bin/mv "$mfc_stage/helper.app" \(Self.quote(Self.installedApp))
        /bin/mv "$mfc_stage/helper.plist" \(Self.quote(Self.plistPath))
        /bin/launchctl bootstrap system \(Self.quote(Self.plistPath))
        """
        try await Self.authorize(command)
    }

    static func uninstall() async throws {
        try await authorize("""
        set -eu
        if /bin/launchctl print system/\(helperServiceName) >/dev/null 2>&1; then
            /bin/launchctl bootout system/\(helperServiceName)
        fi
        /bin/rm -f \(quote(plistPath))
        /bin/rm -rf \(quote(installedApp))
        """)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func verificationCommand(path: String, requirement: String) -> String {
        // codesign treats a requirement without '=' as a filename.
        "/usr/bin/codesign --verify --deep --strict -R " + quote("=" + requirement) + " " + quote(path)
    }

    private static func authorize(_ command: String) async throws {
        try await restoringAuthorizationWindow {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run", command]
                let output = Pipe(); process.standardOutput = output; process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw FanError.message("Helper installation/removal was not completed: " + String(decoding: data, as: UTF8.self))
                }
            }.value
        }
    }

    @MainActor
    static func restoringAuthorizationWindow(_ operation: () async throws -> Void) async rethrows {
        // osascript owns the authorization dialog, so focus does not reliably
        // return to this menu-bar app when the external process exits.
        let candidate = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first {
            $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized
        }
        let window = candidate.flatMap { $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden ? $0 : nil }
        defer {
            // Do not open a window for background launches or resurrect one
            // explicitly closed/minimized while authorization was pending.
            if let window, !window.isMiniaturized, window.isVisible || NSApp.isHidden {
                NSApp.unhide(nil)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
            }
        }
        try await operation()
    }
}

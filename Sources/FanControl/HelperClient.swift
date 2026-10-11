import Foundation
import ServiceManagement
import FanCore

@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    private var localInstallation = try? LocalHelperInstaller()
    private var localEnabled = false
    init() { localEnabled = localInstallation?.installed ?? false }
    var service: SMAppService { .daemon(plistName: helperServiceName + ".plist") }
    // The view reads this on every refresh; a code-signature lookup is not free.
    private let team = SigningIdentity.teamIdentifier()
    var available: Bool { localEnabled || (team != nil && service.status == .enabled) }

    func register() async throws {
        if team == nil {
            let installation = try LocalHelperInstaller()
            try await installation.install()
            localInstallation = installation; localEnabled = installation.installed
            guard localEnabled else { throw FanError.message("Installed helper validation failed.") }
            try await heartbeat()
            return
        }
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func unregister() async throws {
        try await reset()
        if localEnabled { try await LocalHelperInstaller.uninstall(); localEnabled = false }
        else { try await service.unregister() }
        connection?.invalidate(); connection = nil
    }
    private func proxy(errorHandler: @escaping (Error) -> Void) throws -> FanHelperProtocol {
        guard available else {
            throw FanError.message("The fan control helper is not installed. Monitoring continues without it.")
        }
        if connection == nil {
            let new = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            if localEnabled, let installation = localInstallation {
                new.setCodeSigningRequirement(installation.helperRequirement)
            } else if let team = team {
                new.setCodeSigningRequirement(SigningIdentity.requirement(identifier: helperServiceName, team: team))
            } else { throw FanError.message("Helper identity is unavailable.") }
            new.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            new.interruptionHandler = { [weak new] in new?.invalidate() }
            new.resume(); connection = new
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? FanHelperProtocol else {
            throw FanError.message("Cannot connect to the fan helper.")
        }
        return proxy
    }
    // XPC can report both an interruption and a late reply. Resolve each request once.
    private func request(_ invoke: @escaping (FanHelperProtocol, @escaping (String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ReplyOnce(continuation)
            do {
                let proxy = try proxy { completion.finish(.failure($0)) }
                invoke(proxy) { error in
                    if let error { completion.finish(.failure(FanError.message(error))) }
                    else { completion.finish(.success(())) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    completion.finish(.failure(FanError.message("The fan helper did not respond within 5 seconds.")))
                }
            } catch { completion.finish(.failure(error)) }
        }
    }
    func apply(_ modes: [Int: ControlMode]) async throws {
        let data = try JSONEncoder().encode(ControlRequest(modes: modes))
        try await request { $0.apply(data, reply: $1) }
    }
    func heartbeat() async throws { try await request { $0.heartbeat(reply: $1) } }
    func reset() async throws {
        guard connection != nil else { return }
        try await request { $0.reset(reply: $1) }
    }
}

// The continuation is protected by lock across XPC, timeout and actor callbacks.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

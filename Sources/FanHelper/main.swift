import Foundation
import FanCore

// Includes system sleep, unlike uptime; wall-clock adjustments cannot extend a lease.
private func continuousTime() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
}

final class Helper: NSObject, NSXPCListenerDelegate, FanHelperProtocol {
    private let queue = DispatchQueue(label: "local.macsfancontrol.helper.hardware")
    private var session: ControlSession?
    private var connection: NSXPCConnection?
    private var timer: DispatchSourceTimer?
    private var failure: String?
    private let clientRequirement: String
    private var termination: DispatchSourceSignal?
    private var shuttingDown = false

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                if self.shuttingDown { try self.session?.reset(); exit(0) }
                try self.session?.tick(now: continuousTime())
            }
            catch { self.failure = error.localizedDescription }
        }
        self.timer = timer
        timer.resume()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            self.shuttingDown = true
            do { try self.session?.reset(); exit(0) }
            // Keep retrying within launchd's exit grace period after transient
            // SMC failures, without issuing any more manual targets.
            catch { self.failure = error.localizedDescription }
        }
        self.termination = termination; termination.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection incoming: NSXPCConnection) -> Bool {
        // One controlling client at a time prevents interleaved fan ownership.
        let accepted = queue.sync { () -> Bool in
            guard connection == nil, !shuttingDown else { return false }
            connection = incoming; return true
        }
        guard accepted else { return false }
        incoming.setCodeSigningRequirement(clientRequirement)
        incoming.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        incoming.exportedObject = self
        incoming.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                do { try self.session?.reset() } catch { self.failure = error.localizedDescription }
                self.connection = nil
            }
        }
        incoming.interruptionHandler = { [weak incoming] in incoming?.invalidate() }
        incoming.resume()
        return true
    }
    func apply(_ data: Data, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard !self.shuttingDown else { throw FanError.message("The helper is shutting down and restoring automatic control.") }
                guard data.count < 16384 else { throw FanError.message("Request exceeds maximum size.") }
                let request = try JSONDecoder().decode(ControlRequest.self, from: data)
                if self.session == nil { self.session = try ControlSession(hardware: MachineHardware()) }
                try self.session?.apply(request, now: continuousTime())
                self.failure = nil; reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
    func heartbeat(reply: @escaping (String?) -> Void) {
        queue.async {
            // Check expiry before renewal, including after machine sleep.
            do { try self.session?.heartbeat(now: continuousTime()) }
            catch { self.failure = error.localizedDescription }
            reply(self.failure)
        }
    }
    func reset(reply: @escaping (String?) -> Void) {
        queue.async {
            do { try self.session?.reset(); self.failure = nil; reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
}

guard getuid() == 0 else {
    fputs("FanHelper must run as the installed root service.\n", stderr)
    exit(1)
}
let requirement: String
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--client-requirement",
   CommandLine.arguments[2].range(of: #"^cdhash H"[0-9a-f]{40}"$"#, options: .regularExpression) != nil {
    // launchd reads this argument from the administrator-installed root plist.
    requirement = CommandLine.arguments[2]
} else if let team = SigningIdentity.teamIdentifier() {
    requirement = SigningIdentity.requirement(identifier: appBundleIdentifier, team: team)
} else { fputs("No trusted app signature was configured.\n", stderr); exit(1) }
let helper = Helper(clientRequirement: requirement)
let listener = NSXPCListener(machServiceName: helperServiceName)
listener.delegate = helper
listener.resume()
RunLoop.main.run()

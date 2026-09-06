import Darwin
import Foundation

/// Asks a running host to leave and waits until it has actually gone: socket
/// unlinked and process exited, so its instance lock is free for the next
/// host. Falls back to `SIGTERM` when the host does not answer the request.
///
/// Shared by the client (replacing an outdated host) and the app (taking over
/// from a standalone host).
public enum HostRetirement {
    public struct Outcome: Sendable, Equatable {
        /// The host is gone. `false` means it is still listening or alive
        /// after the timeout and the signal.
        public let exited: Bool
        /// The shutdown request was not enough and `SIGTERM` was sent.
        public let usedSignal: Bool

        public init(exited: Bool, usedSignal: Bool) {
            self.exited = exited
            self.usedSignal = usedSignal
        }
    }

    static let pollInterval: Duration = .milliseconds(100)
    static let requestTimeout: TimeInterval = 3
    static let signalGracePeriod: TimeInterval = 2

    /// Sends `shutdownHost(reason)` over `client`, which must be connected,
    /// then waits for the host to exit.
    public static func retire(
        _ client: CommandLineHostClient,
        welcome: Welcome,
        paths: CommandLineHostPaths,
        reason: ShutdownReason,
        timeout: TimeInterval = 5
    ) async -> Outcome {
        _ = try? await Timeouts.withTimeout(seconds: min(requestTimeout, timeout)) {
            try await client.send(.shutdownHost(reason))
        }
        await client.disconnect()
        return await waitForExit(processIdentifier: welcome.processIdentifier, paths: paths, timeout: timeout)
    }

    /// Signals a host that cannot be asked (an older protocol, a dead
    /// connection) and waits for it to exit.
    public static func terminate(processIdentifier: Int32, paths: CommandLineHostPaths, timeout: TimeInterval = 5) async -> Outcome {
        guard isRunning(processIdentifier: processIdentifier, paths: paths) else {
            return Outcome(exited: true, usedSignal: false)
        }
        return await signalAndWait(processIdentifier: processIdentifier, paths: paths, timeout: timeout)
    }

    private static func waitForExit(processIdentifier: Int32, paths: CommandLineHostPaths, timeout: TimeInterval) async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline, isRunning(processIdentifier: processIdentifier, paths: paths) {
            try? await Task.sleep(for: pollInterval)
        }
        guard isRunning(processIdentifier: processIdentifier, paths: paths) else {
            return Outcome(exited: true, usedSignal: false)
        }
        return await signalAndWait(processIdentifier: processIdentifier, paths: paths, timeout: signalGracePeriod)
    }

    private static func signalAndWait(processIdentifier: Int32, paths: CommandLineHostPaths, timeout: TimeInterval) async -> Outcome {
        // Never signal this process: a host running in-process (the app, a
        // test) is stopped through its actor, not from outside.
        guard processIdentifier != getpid() else {
            return Outcome(exited: !isRunning(processIdentifier: processIdentifier, paths: paths), usedSignal: false)
        }
        kill(processIdentifier, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline, isRunning(processIdentifier: processIdentifier, paths: paths) {
            try? await Task.sleep(for: pollInterval)
        }
        return Outcome(exited: !isRunning(processIdentifier: processIdentifier, paths: paths), usedSignal: true)
    }

    /// Still listening on the socket, or still alive. A host inside this
    /// process is judged by its socket alone, since the process is us.
    static func isRunning(processIdentifier: Int32, paths: CommandLineHostPaths) -> Bool {
        if UnixDomainSocket.isHostListening(at: paths.socketURL.path) {
            return true
        }
        guard processIdentifier != getpid() else { return false }
        return kill(processIdentifier, 0) == 0
    }
}

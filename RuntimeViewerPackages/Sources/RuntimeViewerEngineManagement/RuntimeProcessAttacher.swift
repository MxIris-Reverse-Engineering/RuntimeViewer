#if os(macOS)
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUtilities
import RuntimeViewerHelperClient

/// Attaches RuntimeViewer to a running process: picks the payload slice,
/// installs it, injects it, and hands back the engine that ends up talking to
/// the target.
///
/// This is the flow `AttachToProcessViewModel` used to run inline. It lives
/// here so a process without a window can attach too; the ViewModel is now
/// one caller among several. The two probes are injectable only so the
/// transport decision can be tested without a live target.
@Loggable
@MainActor
public final class RuntimeProcessAttacher {
    public struct Target: Sendable, Hashable {
        public let name: String
        public let processIdentifier: pid_t

        public init(name: String, processIdentifier: pid_t) {
            self.name = name
            self.processIdentifier = processIdentifier
        }
    }

    /// How the injected payload reaches back to this process.
    public enum Transport: Sendable, Hashable {
        /// A Mac target that can look up our Mach service: the payload connects
        /// to the XPC listener this process brings up.
        case xpc
        /// A Mac target whose sandbox denies mach-lookup: the payload dials a
        /// localhost socket instead.
        case localSocket
        /// An iOS Simulator target: the payload advertises over Bonjour and the
        /// browser already running in this process connects to it.
        case simulatorBonjour
    }

    public struct Outcome: Sendable {
        public let engine: RuntimeEngine
        public let transport: Transport
        public let payloadPlatform: PayloadPlatform
    }

    /// What ``attach(_:)`` settled on before touching the helper daemon.
    ///
    /// Pure, so the decision table is testable without a daemon or a live
    /// target: the probes are the only inputs that touch another process.
    enum Route: Hashable {
        case xpc
        case localSocket
        case simulatorBonjour(deviceID: String)

        var transport: Transport {
            switch self {
            case .xpc: return .xpc
            case .localSocket: return .localSocket
            case .simulatorBonjour: return .simulatorBonjour
            }
        }
    }

    private let engineManager: RuntimeEngineManager
    private let injectClient: RuntimeInjectClient
    private let sandboxProbe: @Sendable (pid_t) -> Bool
    private let environmentProbe: @Sendable (pid_t) -> [String: String]?

    /// - Parameters:
    ///   - sandboxProbe: Whether the target's live sandbox denies mach-lookup of
    ///     our service. The default asks the kernel rather than reading the
    ///     target's entitlements, which miss seatbelt-profiled daemons
    ///     (rapportd and friends) that deny mach-lookup without carrying
    ///     `com.apple.security.app-sandbox`.
    ///   - environmentProbe: The target's environment, read for `SIMULATOR_UDID`.
    public init(
        engineManager: RuntimeEngineManager,
        injectClient: RuntimeInjectClient,
        sandboxProbe: @escaping @Sendable (pid_t) -> Bool = { processIdentifier in
            SandboxProbe.isMachLookupBlocked(pid: processIdentifier, globalName: RuntimeViewerMachServiceName)
        },
        environmentProbe: @escaping @Sendable (pid_t) -> [String: String]? = { processIdentifier in
            ProcessEnvironmentProbe.environment(ofProcess: processIdentifier)
        }
    ) {
        self.engineManager = engineManager
        self.injectClient = injectClient
        self.sandboxProbe = sandboxProbe
        self.environmentProbe = environmentProbe
    }

    // MARK: - Attach

    public func attach(_ target: Target) async throws -> Outcome {
        // Which slice the target can load. A macOS process and an iOS
        // Simulator process on this Mac share a cputype and are told apart
        // only by their LC_BUILD_VERSION, so this has to be read rather than
        // assumed — and it throws for a target we ship no payload for, instead
        // of handing over the nearest slice and letting dyld refuse it.
        let payloadPlatform = try injectClient.payloadPlatform(forTargetProcess: target.processIdentifier)
        // Decided before the install so a target we cannot route to costs
        // nothing; both probes are local reads.
        let route = try Self.route(
            for: target,
            payloadPlatform: payloadPlatform,
            sandboxProbe: sandboxProbe,
            environmentProbe: environmentProbe
        )
        try await injectClient.installServerFrameworkIfNeeded(for: payloadPlatform)
        // Every other failure in this method throws and reaches the caller. A
        // bare `return` here would report nothing at all — the user clicks
        // Attach and watches nothing happen.
        guard let dylibURL = injectClient.serverFrameworkExecutableURL(for: payloadPlatform) else {
            throw RuntimeInjectClient.Error.serverFrameworkNotFound(payloadPlatform)
        }

        let engine: RuntimeEngine
        switch route {
        case .xpc:
            engine = try await attachToLocalProcess(target, isSandbox: false, dylibURL: dylibURL)
        case .localSocket:
            engine = try await attachToLocalProcess(target, isSandbox: true, dylibURL: dylibURL)
        case .simulatorBonjour(let deviceID):
            engine = try await attachToSimulatorProcess(target, deviceID: deviceID, dylibURL: dylibURL)
        }
        return Outcome(engine: engine, transport: route.transport, payloadPlatform: payloadPlatform)
    }

    /// The transport for `target`, from the payload slice it needs and what
    /// the probes say about it.
    ///
    /// A simulator target never consults the sandbox probe: that probe exists
    /// to choose between XPC and the localhost socket, and a simulator payload
    /// takes neither — its transport is fixed at compile time and is always
    /// Bonjour (see `RuntimeViewerServer.main()`).
    static func route(
        for target: Target,
        payloadPlatform: PayloadPlatform,
        sandboxProbe: (pid_t) -> Bool,
        environmentProbe: (pid_t) -> [String: String]?
    ) throws -> Route {
        switch payloadPlatform {
        case .macOS:
            return sandboxProbe(target.processIdentifier) ? .localSocket : .xpc
        case .iOSSimulator:
            // Which simulator the target belongs to. The pid alone cannot
            // identify the payload's advertisement — pids are per device, and
            // the endpoint key the payload lands under is `{deviceID}-{pid}`.
            guard let deviceID = environmentProbe(target.processIdentifier)?["SIMULATOR_UDID"],
                  !deviceID.isEmpty
            else {
                throw RuntimeEngineManager.AttachedEngineHandshakeError.simulatorDeviceUnidentifiable(
                    name: target.name,
                    processIdentifier: target.processIdentifier
                )
            }
            return .simulatorBonjour(deviceID: deviceID)
        }
    }

    /// The Mac flow: bring up a client engine, inject, confirm the payload
    /// connected back to it.
    private func attachToLocalProcess(_ target: Target, isSandbox: Bool, dylibURL: URL) async throws -> RuntimeEngine {
        let identifier = target.processIdentifier.description
        let engine = try await engineManager.launchAttachedRuntimeEngine(name: target.name, identifier: identifier, isSandbox: isSandbox)
        do {
            try await inject(processIdentifier: target.processIdentifier, dylibURL: dylibURL)
            // `connect()` only brought up the local half and optimistically
            // reported `.connected`; confirm the injected peer actually
            // connected back, so a rejected connection surfaces an error and
            // the engine is torn down instead of lingering silently.
            try await engineManager.confirmAttachedRuntimeEngineConnected(name: target.name, identifier: identifier, isSandbox: isSandbox)
        } catch {
            engineManager.terminateAttachedRuntimeEngine(name: target.name, identifier: identifier, isSandbox: isSandbox)
            throw error
        }
        return engine
    }

    /// The simulator flow: inject, then wait for the payload to advertise itself.
    ///
    /// No engine is launched first, and none has to be torn down on failure.
    /// The browser already running in this process is what connects to the
    /// payload; the XPC/socket endpoint the Mac flow prepares would never be
    /// dialled.
    private func attachToSimulatorProcess(_ target: Target, deviceID: String, dylibURL: URL) async throws -> RuntimeEngine {
        try await inject(processIdentifier: target.processIdentifier, dylibURL: dylibURL)
        return try await engineManager.awaitInjectedBonjourEngine(
            name: target.name,
            deviceID: deviceID,
            processIdentifier: target.processIdentifier
        )
    }

    /// dlopen or mach_vm_remap is the daemon's call — it probes the target's
    /// sandbox and code signing to find out which one the target will accept.
    /// All we owe it is the entry symbol the remap path needs.
    private func inject(processIdentifier: pid_t, dylibURL: URL) async throws {
        try await injectClient.injectApplication(
            pid: processIdentifier,
            dylibURL: dylibURL,
            remapEntrySymbol: "runtime_viewer_server_start"
        )
    }

    // MARK: - Detach

    /// Tears down whatever ``attach(_:)`` produced for `target`.
    ///
    /// A Mac target is found by pid among the attached engines. A simulator
    /// target is found by device and pid among the Bonjour engines, which
    /// needs the process to still be alive so its `SIMULATOR_UDID` can be
    /// read; a dead simulator process drops off on its own when its
    /// advertisement disappears.
    public func detach(_ target: Target) {
        let identifier = target.processIdentifier.description
        for engine in engineManager.attachedRuntimeEngines {
            switch engine.source {
            case .remote(_, let sourceIdentifier, .client) where sourceIdentifier.rawValue == identifier,
                 .localSocket(_, let sourceIdentifier, .client) where sourceIdentifier.rawValue == identifier:
                engineManager.terminateRuntimeEngine(for: engine.source)
            default:
                continue
            }
        }

        if let deviceID = environmentProbe(target.processIdentifier)?["SIMULATOR_UDID"],
           !deviceID.isEmpty,
           let engine = engineManager.injectedBonjourEngine(deviceID: deviceID, processIdentifier: target.processIdentifier) {
            engineManager.terminateRuntimeEngine(for: engine.source)
        }
    }
}
#endif

import Foundation
import RuntimeViewerCore
#if os(macOS)
import RuntimeViewerEngineManagement
import RuntimeViewerHelperClient
#endif

/// A stage of an attach, as reported to the client.
public enum AttachPhase: Sendable, Hashable {
    case installingPayload(platform: String)
    case injecting
    case awaitingConnection(transport: String)

    /// The progress frame for this phase.
    public func progress(processName: String) -> CommandProgress {
        switch self {
        case .installingPayload(let platform):
            return CommandProgress(phase: "installing payload", detail: platform)
        case .injecting:
            return CommandProgress(phase: "injecting", detail: processName)
        case .awaitingConnection(let transport):
            return CommandProgress(phase: "awaiting connection", detail: transport)
        }
    }
}

/// What an attach produced.
public struct AttachOutcome: Sendable {
    public static let simulatorBonjourTransport = "simulatorBonjour"

    public let engine: RuntimeEngine
    /// `xpc`, `localSocket` or `simulatorBonjour`.
    public let transport: String
    /// The payload slice that was injected, e.g. `macOS` or `iOS Simulator`.
    public let payloadPlatform: String

    public init(engine: RuntimeEngine, transport: String, payloadPlatform: String) {
        self.engine = engine
        self.transport = transport
        self.payloadPlatform = payloadPlatform
    }

    /// A simulator process connects back over Bonjour; its engine is named by
    /// identifier, never by pid.
    public var reachedOverBonjour: Bool {
        transport == Self.simulatorBonjourTransport
    }
}

/// Injects into a process. `RuntimeProcessAttacher` in production; tests
/// substitute something that never touches the helper daemon.
public protocol ProcessAttaching: Sendable {
    func attach(name: String, processIdentifier: Int32, progress: @escaping @Sendable (AttachPhase) -> Void) async throws -> AttachOutcome
}

#if os(macOS)
/// The production attacher: the same code path as the app's Attach Process sheet.
@MainActor
public final class RuntimeProcessAttacherAdapter: ProcessAttaching {
    private let attacher: RuntimeProcessAttacher

    public init(attacher: RuntimeProcessAttacher) {
        self.attacher = attacher
    }

    public func attach(name: String, processIdentifier: Int32, progress: @escaping @Sendable (AttachPhase) -> Void) async throws -> AttachOutcome {
        let target = RuntimeProcessAttacher.Target(name: name, processIdentifier: processIdentifier)
        let outcome = try await attacher.attach(target) { phase in
            progress(AttachPhase(phase))
        }
        return AttachOutcome(
            engine: outcome.engine,
            transport: outcome.transport.wireName,
            payloadPlatform: outcome.payloadPlatform.displayName
        )
    }
}

extension AttachPhase {
    init(_ phase: RuntimeProcessAttacher.Phase) {
        switch phase {
        case .installingPayload(let platform):
            self = .installingPayload(platform: platform.displayName)
        case .injecting:
            self = .injecting
        case .awaitingConnection(let transport):
            self = .awaitingConnection(transport: transport.wireName)
        }
    }
}

extension RuntimeProcessAttacher.Transport {
    /// The name that travels in `AttachResult.transport`.
    var wireName: String {
        switch self {
        case .xpc: return "xpc"
        case .localSocket: return "localSocket"
        case .simulatorBonjour: return AttachOutcome.simulatorBonjourTransport
        }
    }
}
#endif

import Foundation
import FoundationToolbox
import RuntimeViewerCommunication

/// The `DYLD_ROOT_PATH` of the process that owns an engine's images: what
/// turns a path as a client spells it into the key the serving process keeps
/// it under.
final class RuntimeEngineDyldRootPath: Sendable {
    private let rootPath: Mutex<String?>

    init(_ rootPath: String?) {
        self.rootPath = Mutex(rootPath)
    }

    var value: String? {
        rootPath.withLock { $0 }
    }

    func update(_ newRootPath: String?) {
        rootPath.withLock { $0 = newRootPath }
    }
}

extension RuntimeEngine {
    /// How often a client asks its peer for the peer's `DYLD_ROOT_PATH`, how
    /// long it waits between two questions, and how long for an answer. A
    /// proxy installs its command table only once a client has connected, so
    /// the first question can arrive before it can be answered; a peer older
    /// than 2.1.0 does not answer a command it does not know at all.
    static let servingDyldRootPathAttemptCount = 4

    static let servingDyldRootPathRetryDelayNanoseconds: UInt64 = 250_000_000

    static let servingDyldRootPathTimeout: TimeInterval = 3

    /// `imagePath` as the process that owns this engine's images keys it —
    /// the form corpus coverage, the indexed image list, search summaries and
    /// every `RuntimeObject.imagePath` carry. Identity for a Mac process; for
    /// a process in the iOS Simulator it prefixes that process's
    /// `DYLD_ROOT_PATH`, which a path from the sidebar, the background
    /// indexer or a search scope leaves out. Idempotent: a path already in
    /// that form comes back unchanged.
    public nonisolated func canonicalImagePath(_ imagePath: String) -> String {
        DyldUtilities.patchImagePathForDyld(imagePath, rootPath: servingDyldRootPath.value)
    }

    /// Test seam: the root `canonicalImagePath(_:)` applies — and, for an
    /// engine that does its own work, the one it answers a client's question
    /// with — without a simulator.
    nonisolated func setDyldRootPathForTesting(_ rootPath: String?) {
        servingDyldRootPath.update(rootPath)
    }

    /// Whether a client engine on `source` asks its peer for that peer's
    /// `DYLD_ROOT_PATH`. Only a socket can lead to a process in the iOS
    /// Simulator. An XPC peer — the local-runtime service, the Catalyst
    /// helper, an app injected over a Mach service — is a Mac process, whose
    /// root is `nil`; and a payload of an earlier release injected over a
    /// Mach service takes a command it does not know for its client going
    /// away (PR121.73), so it is never sent one.
    ///
    /// `injectedTCP` is a socket and still not asked. It leads only to a
    /// payload on a real device — a simulator's payload advertises over
    /// Bonjour instead — whose root is `nil`. And there the question costs
    /// more than a round trip: the engine manager tells a target that exited
    /// from a link that dropped by how the socket ended, a close or a reset,
    /// and a payload that exits with the question still unread resets the
    /// connection instead of closing it, so the target would be kept as if
    /// only its link had dropped.
    static func asksForServingDyldRootPath(on source: RuntimeSource) -> Bool {
        switch source {
        case .bonjour(_, _, let role),
             .localSocket(_, _, let role),
             .directTCP(_, _, _, let role):
            role.isClient
        case .local,
             .remote,
             .injectedTCP:
            false
        }
    }

    /// The question a client asks its peer, answered with the
    /// `DYLD_ROOT_PATH` of the process that owns the peer's images.
    ///
    /// Answered from what the serving engine already knows, and never
    /// forwarded — the registrar installs it with
    /// `registerAnsweredInThisProcess(_:)`, not `register(_:)`: the root of its
    /// own process for an engine that does its own work, the root it learned
    /// on connecting for one that forwards over a socket — a proxy in front
    /// of a simulator process — and its own process's, `nil`, for one that
    /// forwards over XPC, whose peer is a Mac process and may be a payload of
    /// an earlier release that must not be sent a command it does not know.
    struct DyldRootPathCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.dyldRootPath.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String? {
            engine.servingDyldRootPath.value
        }
    }
}

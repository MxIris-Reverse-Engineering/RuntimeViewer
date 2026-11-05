import Foundation
// Re-exports OSToolbox, where the `#log` macro lives.
import FoundationToolbox
import RuntimeViewerCommunication

/// Installs a set of commands onto one connection.
///
/// A value rather than a few free functions because it crosses a module
/// boundary: an extension module declared through
/// ``RuntimeEngine/addCommandExtension(named:install:)`` is handed this and
/// nothing else — not the connection, and not the engine.
///
/// `@unchecked Sendable`: its whole lifetime is a single synchronous assembly
/// call, made while a connection is being set up, and it never crosses an
/// isolation domain. The annotation exists only so it can be the parameter of
/// an `@Sendable` closure.
public final class RuntimeEngineCommandRegistrar: @unchecked Sendable {
    /// The wire names installed so far.
    ///
    /// Both the basis for duplicate detection and what tests assert on — the
    /// replacement for the `CaseIterable.allCases` uniqueness check the closed
    /// enum used to allow.
    public private(set) var installedCommandNames: Set<String> = []

    private let connection: any RuntimeConnection

    private let engine: RuntimeEngine

    /// The connection's registry of requests its peer can still withdraw; see
    /// ``registerProgress(_:)`` and `registerRequestCancellation()`.
    private let inboundRequests: RuntimeEngineInboundRequests

    /// - Parameter inboundRequests: The registry the connection's owner keeps
    ///   for it. An identifier means something only to the peer that minted
    ///   it, so the owner of a connection whose handlers are installed again —
    ///   an engine reconnecting, a proxy taking its next client — passes the
    ///   one it keeps, and a request survives the reinstallation. The default,
    ///   a registry of this registrar's own, serves a connection whose handlers
    ///   are installed once.
    init(
        connection: any RuntimeConnection,
        engine: RuntimeEngine,
        inboundRequests: RuntimeEngineInboundRequests = RuntimeEngineInboundRequests()
    ) {
        self.connection = connection
        self.engine = engine
        self.inboundRequests = inboundRequests
    }

    /// Installs one plain command, routing inbound requests of that type
    /// through `engine.dispatch(_:)`.
    ///
    /// A command name that is already installed is **dropped, and a `.fault` is
    /// logged**. First come wins rather than last one overwrites: the built-in
    /// commands are installed first, so no extension module can take a name of
    /// Core's, whether it means to or not.
    ///
    /// Routing through `dispatch` (rather than calling `perform(on: engine)`
    /// directly) matters for `RuntimeEngineProxyServer`: the proxied engine may
    /// itself be a *client* of another process (e.g. the Mac Catalyst helper or
    /// an attached app reached over XPC / local socket). `dispatch` forwards the
    /// request upstream in that case, so commands like `loadImage` run in the
    /// process that actually owns the image. Calling `perform(on:)` here would
    /// run the local implementation in the proxy host process instead — which
    /// is how remote image loading regressed after the request unification
    /// (dlopen of e.g. `/System/iOSSupport/.../UIKitCore` in the wrong
    /// process). For server / local engines `dispatch` falls through to
    /// `perform(on:)`, so their behavior is unchanged.
    public func register<Command: RuntimeEngineCommand>(_ commandType: Command.Type) {
        guard claim(Command.commandName) else { return }
        connection.setMessageHandler(name: Command.commandName) { [engine] (command: Command) -> Command.Response in
            try await engine.dispatch(command)
        }
    }

    /// Installs one progress-reporting command.
    ///
    /// The handler decodes the progress envelope, executes through
    /// `engine.dispatch(_:onProgress:)`, and relays every progress event back
    /// to the requesting peer tagged with the requester's token. Chained
    /// proxies compose with no per-command code: when the proxied engine is a
    /// client, its `dispatch` forwards the request upstream under a fresh
    /// token and the upstream's pushes flow into this closure, which re-pushes
    /// them downstream under the original requester's token.
    ///
    /// The progress push is best-effort (`try?`) — a dropped push must not
    /// fail the request itself, matching the pre-existing behavior of the
    /// hand-rolled `objectsLoadingProgress` channel this replaces.
    ///
    /// A request whose envelope names itself — a command type that cancels
    /// across connections — runs in a task `inboundRequests` holds, so the
    /// sender's `cancelRequest` can reach it: the transport runs this handler
    /// in a task nobody holds a handle to. Through a proxy whose engine is
    /// itself a client, cancelling that task cancels the engine's own
    /// forwarded request, which withdraws it upstream in turn.
    public func registerProgress<Command: RuntimeEngineProgressCommand>(_ commandType: Command.Type) {
        guard claim(Command.commandName) else { return }
        let connection = connection
        connection.setMessageHandler(name: Command.commandName) { [engine, inboundRequests] (envelope: RuntimeEngineProgressEnvelope<Command>) -> Command.Response in
            let onProgress: (@Sendable (Command.Progress) async -> Void)?
            if let token = envelope.progressToken {
                onProgress = { progress in
                    guard let payload = try? JSONEncoder().encode(progress) else { return }
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandName.progressEvent.commandName,
                        request: RuntimeEngineProgressPush(token: token, payload: payload),
                    )
                }
            } else {
                onProgress = nil
            }
            guard let requestIdentifier = envelope.requestIdentifier else {
                return try await engine.dispatch(envelope.request, onProgress: onProgress)
            }
            return try await inboundRequests.run(requestIdentifier) {
                try await engine.dispatch(envelope.request, onProgress: onProgress)
            }
        }
    }

    // MARK: - Commands answered by this process

    /// Installs `cancelRequest`, which withdraws a request this connection is
    /// serving, named by the `requestIdentifier` its envelope carried.
    ///
    /// Answered here and never forwarded: the identifier names a task in this
    /// process. On a proxy whose engine forwards in turn, cancelling that task
    /// is what sends the next `cancelRequest` upstream.
    func registerRequestCancellation() {
        let commandName = RuntimeEngine.CommandName.cancelRequest.commandName
        guard claim(commandName) else { return }
        connection.setMessageHandler(name: commandName) { [inboundRequests] (cancellation: RuntimeEngineRequestCancellation) in
            await inboundRequests.cancel(cancellation.requestIdentifier)
        }
    }

    /// Installs one command that this process answers itself, running
    /// `perform(on:)` directly instead of going through `engine.dispatch(_:)`.
    ///
    /// The opposite of what ``register(_:)`` has to do, and right only for a
    /// command whose answer belongs to the process serving this connection
    /// rather than to the process that owns the images: `dyldRootPath`, which
    /// an engine answers from what it already knows (see
    /// `RuntimeEngine.DyldRootPathCommand`). Internal, because no command of
    /// another module has had a reason to be answered this way.
    func registerAnsweredInThisProcess<Command: RuntimeEngineCommand>(_ commandType: Command.Type) {
        guard claim(Command.commandName) else { return }
        connection.setMessageHandler(name: Command.commandName) { [engine] (command: Command) -> Command.Response in
            try await command.perform(on: engine)
        }
    }

    private func claim(_ commandName: String) -> Bool {
        guard installedCommandNames.insert(commandName).inserted else {
            RuntimeEngineCommandRegistryLog.duplicateCommandName(commandName)
            return false
        }
        return true
    }
}

// MARK: - Logging

/// The registrar's log line. `@Loggable`'s generated logger is private to the
/// file that declares it, so `RuntimeEngine+CommandExtensions.swift` keeps its
/// own.
@Loggable(.private)
private enum RuntimeEngineCommandRegistryLog {
    static func duplicateCommandName(_ commandName: String) {
        #log(.fault, "Two command declarations claim the wire name \(commandName, privacy: .public); the later registration was dropped. The first one installed keeps the name — for a built-in command that is Core's own.")
    }
}

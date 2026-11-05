import Foundation

/// A `RuntimeEngineCommand` whose execution emits incremental progress
/// alongside its final response.
///
/// Conformers get the full progress pipeline for free — client-side routing,
/// server-side push-back, and transparent relaying across chained proxies
/// (a `RuntimeEngineProxyServer` wrapping an engine that is itself a client
/// of another process). Declaring a new progress-bearing command reduces to:
///  1. conforming the request type to this protocol, and
///  2. registering it with `RuntimeEngineCommandRegistrar.registerProgress(_:)`
///     instead of `register(_:)`.
///
/// ## Wire form
/// Progress requests travel as `RuntimeEngineProgressEnvelope`
/// (`{progressToken, request, requestIdentifier}`) under the command's own
/// `commandName` — never as the bare command, so plain and
/// progress-listening callers share one server handler. While the request
/// executes, the serving peer pushes `RuntimeEngineProgressPush`
/// (`{token, payload}`) frames on the shared `CommandName.progressEvent`
/// channel; the requesting engine routes each push back to the in-flight call
/// by token, so concurrent requests never cross-talk. A `nil` token means the
/// caller doesn't observe progress and the serving peer skips the pushes
/// entirely.
///
/// ## Cancellation
/// A command type that opts in through `cancelsAcrossConnections` names each
/// round trip with a `requestIdentifier`. Cancelling its caller then returns
/// the caller at once and withdraws the request from the serving peer with
/// `CommandName.cancelRequest` — see `RuntimeEngineInboundRequests` and
/// `RuntimeEngineForwardedRequest`, and `CommunicationAndEngineArchitecture.md`
/// §4.5 for the protocol.
public protocol RuntimeEngineProgressCommand: RuntimeEngineCommand {
    associatedtype Progress: Codable & Sendable

    /// Whether cancelling the caller of a forwarded request withdraws it in
    /// the serving process too. Opt in only for a command no peer serves
    /// without also knowing `cancelRequest` — one added in the same release
    /// as `cancelRequest`, or later: a peer that predates it does not ignore
    /// an unknown message on every transport (an injected payload reached
    /// over a Mach service takes one for its client going away). A command of
    /// another module is held to the same rule: its registrar withdraws it
    /// exactly as it withdraws Core's.
    static var cancelsAcrossConnections: Bool { get }

    /// Local implementation reporting incremental progress. Implementations
    /// must `await` `reportProgress` at each report site so events stay
    /// ordered end-to-end (the wire layer serializes on that await).
    func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (Progress) async -> Void) async throws -> Response
}

extension RuntimeEngineProgressCommand {
    public static var cancelsAcrossConnections: Bool {
        false
    }

    /// Plain execution defaults to the progress-bearing variant with a no-op
    /// listener, so conformers implement a single method.
    public func perform(on engine: RuntimeEngine) async throws -> Response {
        try await perform(on: engine) { _ in }
    }
}

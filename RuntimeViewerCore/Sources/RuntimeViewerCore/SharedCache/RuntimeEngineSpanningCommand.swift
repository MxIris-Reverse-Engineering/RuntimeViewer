import Foundation

/// A request about every image an engine has indexed — no single subject
/// image to route it by.
///
/// An engine that borrows shared cache images answers it with every
/// participant's part: its own images' from its serving process, and each
/// owner's from that owner's. The command says how: which request each
/// participant gets, what of its answer is kept — only the images it is
/// responsible for — and how the parts make one answer, the one the request
/// would have got had one engine indexed every image. `dispatch(_:)` asks for
/// it whenever the engine has owners and the request names no subject image.
///
/// A command that reports progress conforms to
/// ``RuntimeEngineSpanningProgressCommand`` instead.
public protocol RuntimeEngineSpanningCommand: RuntimeEngineCommand {
    /// This request answered across `participants`, the requested engine
    /// first.
    func response(across participants: [RuntimeSharedCacheParticipant]) async throws -> Response
}

/// ``RuntimeEngineSpanningCommand`` for a request that reports progress: a
/// participant's progress is passed on as it arrives, holding only the images
/// that participant answers for.
public protocol RuntimeEngineSpanningProgressCommand: RuntimeEngineProgressCommand {
    /// This request answered across `participants`, the requested engine
    /// first, with each participant's progress passed to `onProgress`.
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (Progress) async -> Void)?
    ) async throws -> Response
}

// MARK: - Dispatching through an existential

// `dispatch(_:)` meets a spanning command as `any` one of these protocols,
// whose `Response` and `Progress` it cannot name; these erase them so the
// dispatch can cast the answer back to its own command's types.

extension RuntimeEngineSpanningCommand {
    func erasedResponse(across participants: [RuntimeSharedCacheParticipant]) async throws -> any Sendable {
        try await response(across: participants)
    }
}

extension RuntimeEngineSpanningProgressCommand {
    func erasedResponse(
        across participants: [RuntimeSharedCacheParticipant],
        onErasedProgress: (@Sendable (any Sendable) async -> Void)?
    ) async throws -> any Sendable {
        guard let onErasedProgress else {
            return try await response(across: participants, onProgress: nil)
        }
        return try await response(across: participants) { progress in
            await onErasedProgress(progress)
        }
    }
}

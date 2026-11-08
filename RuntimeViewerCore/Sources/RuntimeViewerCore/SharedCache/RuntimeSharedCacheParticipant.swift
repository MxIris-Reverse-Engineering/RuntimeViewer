import Foundation

/// One engine that answers part of a request about every image, for an
/// engine that borrows shared cache images: the engine itself, for the images
/// it does not borrow, and each owner, for the images it keeps.
///
/// A request about every image an engine has indexed — a search, the
/// relationships of a type, the callers of a function — asks each
/// participant, keeps from each answer the images that participant is
/// responsible for, and combines what is left. See
/// `RuntimeEngineSpanningCommand`.
public struct RuntimeSharedCacheParticipant: Sendable {
    /// The participant's engine.
    public let engine: RuntimeEngine

    /// Whether this participant answers for an image. The engine the request
    /// was sent to answers for every image it does not borrow; an owner for
    /// the shared cache images it keeps. No image is answered for twice.
    public let includesImage: @Sendable (String) -> Bool

    /// Whether this is the engine the request was sent to rather than an
    /// owner of its borrowed images.
    public let isRequestedEngine: Bool

    init(engine: RuntimeEngine, isRequestedEngine: Bool, includesImage: @escaping @Sendable (String) -> Bool) {
        self.engine = engine
        self.isRequestedEngine = isRequestedEngine
        self.includesImage = includesImage
    }

    /// `command` answered by this participant's serving process — never
    /// handed on to owners of its own.
    public func dispatch<Command: RuntimeEngineCommand>(_ command: Command) async throws -> Command.Response {
        try await engine.dispatchToServingProcess(command)
    }

    /// `dispatch(_:)` for a request that reports progress.
    public func dispatch<Command: RuntimeEngineProgressCommand>(
        _ command: Command,
        onProgress: (@Sendable (Command.Progress) async -> Void)?
    ) async throws -> Command.Response {
        try await engine.dispatchToServingProcess(command, onProgress: onProgress)
    }
}

extension Array where Element == RuntimeSharedCacheParticipant {
    /// `body` for every participant at once, the results in participant
    /// order — the requested engine's first.
    ///
    /// The requested engine failing fails the request. An owner failing
    /// leaves its part out instead: an owner whose process went away must not
    /// cost the borrowing engine its own answer. A cancellation is never
    /// taken for an owner's failure.
    public func concurrentResults<Result: Sendable>(
        _ body: @escaping @Sendable (RuntimeSharedCacheParticipant) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result?).self) { group in
            for (index, participant) in enumerated() {
                group.addTask {
                    do {
                        return (index, try await body(participant))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch _ where !participant.isRequestedEngine {
                        return (index, nil)
                    }
                }
            }
            var resultsByIndex: [Int: Result] = [:]
            for try await (index, result) in group {
                resultsByIndex[index] = result
            }
            return indices.compactMap { resultsByIndex[$0] }
        }
    }

    /// The engine the request was sent to.
    public var requestedEngine: RuntimeSharedCacheParticipant? {
        first { $0.isRequestedEngine }
    }

    /// The owners of the requested engine's borrowed images.
    public var owners: [RuntimeSharedCacheParticipant] {
        filter { !$0.isRequestedEngine }
    }
}

extension Array where Element == RuntimeSharedCacheParticipant {
    /// For each of `names`, the ancestors tree of the type of that name some
    /// owner among these participants has indexed — at most `limit` names,
    /// one query per owner for all of them. A name no owner knows has no
    /// tree, and an owner that cannot answer is passed over.
    func ownersAncestorTrees(named names: some Collection<String>, limit: Int = 64) async -> [String: RuntimeRelationshipTree] {
        let requestedNames: [String] = names.prefix(limit).map { $0 }
        guard !requestedNames.isEmpty else { return [:] }
        // A pattern with a dot in it is matched against qualified names, one
        // without against a type's own name; the two kinds go separately.
        let nameGroups: [[String]] = [requestedNames.filter { !$0.contains(".") }, requestedNames.filter { $0.contains(".") }].filter { !$0.isEmpty }
        var treesByName: [String: RuntimeRelationshipTree] = [:]
        for owner in owners {
            let remainingGroups = nameGroups.map { group in group.filter { treesByName[$0] == nil } }.filter { !$0.isEmpty }
            for group in remainingGroups {
                let pattern = "^(?:" + group.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")$"
                let query = RuntimeTypeRelationshipsQuery(
                    text: pattern,
                    matchMode: .regularExpression,
                    relationship: .ancestors,
                    isCaseSensitive: true,
                    candidateLimit: group.count * 4
                )
                guard let trees = try? await owner.dispatch(RuntimeEngine.TypeRelationshipsCommand(query: query), onProgress: nil) else { continue }
                for name in group where treesByName[name] == nil {
                    if let tree = trees.first(where: { owner.includesImage($0.root.imagePath) && $0.root.isNamed(name) }) {
                        treesByName[name] = tree
                    }
                }
            }
        }
        return treesByName
    }
}

import Foundation
import OrderedCollections

// Core's requests about every image, answered across an engine that borrows
// shared cache images and its owners. Each participant answers for its own
// images only — the requested engine for the images it does not borrow, an
// owner for the ones it keeps — so no image is answered for twice, not even
// one a participant happens to have indexed for some other reason.

// MARK: - Relationships

extension RuntimeEngine.RelationshipsCommand: RuntimeEngineSpanningCommand {
    func response(across participants: [RuntimeSharedCacheParticipant]) async throws -> RuntimeRelationships {
        let parts = try await participants.concurrentResults { participant in
            let relationships = try await participant.dispatch(self)
            return RuntimeRelationships(
                subclasses: relationships.subclasses.filter { participant.includesImage($0.imagePath) },
                conformingTypes: relationships.conformingTypes.filter { participant.includesImage($0.imagePath) }
            )
        }
        return RuntimeRelationships(
            subclasses: Array(OrderedSet(parts.flatMap(\.subclasses))),
            conformingTypes: Array(OrderedSet(parts.flatMap(\.conformingTypes)))
        )
    }
}

// MARK: - Indexed images

extension RuntimeEngine.IndexedImagePathsCommand: RuntimeEngineSpanningCommand {
    func response(across participants: [RuntimeSharedCacheParticipant]) async throws -> [String] {
        let parts = try await participants.concurrentResults { participant in
            try await participant.dispatch(self).filter(participant.includesImage)
        }
        return Set(parts.joined()).sorted()
    }
}

// MARK: - Restoring corpora

extension RuntimeEngine.RestoreInterfaceCorporaCommand: RuntimeEngineSpanningProgressCommand {
    /// Each participant restores only its own images: an owner asked for an
    /// image it does not keep would read it into its store all the same.
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeEngineEmpty) async -> Void)?
    ) async throws -> RuntimeInterfaceCorpusRestoreResult {
        let parts = try await participants.concurrentResults { participant -> RuntimeInterfaceCorpusRestoreResult in
            let participantImagePaths = imagePaths.filter(participant.includesImage)
            guard !participantImagePaths.isEmpty else { return .empty }
            return try await participant.dispatch(
                RuntimeEngine.RestoreInterfaceCorporaCommand(imagePaths: participantImagePaths, transformer: transformer),
                onProgress: nil
            )
        }
        var restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage] = [:]
        for part in parts {
            restoredImagesByImagePath.merge(part.restoredImagesByImagePath) { restoredImage, _ in restoredImage }
        }
        return RuntimeInterfaceCorpusRestoreResult(restoredImagesByImagePath: restoredImagesByImagePath)
    }
}

// MARK: - Searches

extension RuntimeEngine.SearchInterfacesCommand: RuntimeEngineSpanningProgressCommand {
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeInterfaceSearchBatch) async -> Void)?
    ) async throws -> RuntimeInterfaceSearchSummary {
        let budget = RuntimeSpanningResultBudget(limit: query.resultLimit)
        let parts = try await participants.concurrentResults { participant -> RuntimeInterfaceSearchSummary? in
            var participantQuery = query
            if let imagePaths = query.imagePaths {
                let participantImagePaths = imagePaths.filter(participant.includesImage)
                guard !participantImagePaths.isEmpty else { return nil }
                participantQuery.imagePaths = participantImagePaths
            }
            let forwardBatch: (@Sendable (RuntimeInterfaceSearchBatch) async -> Void)? = onProgress.map { onProgress in
                { batch in
                    let results = batch.results().filter { participant.includesImage($0.object.imagePath) }
                    let admittedCount = await budget.admit(results.count)
                    guard admittedCount > 0 else { return }
                    await onProgress(RuntimeInterfaceSearchBatch(Array(results.prefix(admittedCount))))
                }
            }
            let summary = try await participant.dispatch(RuntimeEngine.SearchInterfacesCommand(query: participantQuery), onProgress: forwardBatch)
            return summary.keepingImages(where: participant.includesImage)
        }
        return RuntimeInterfaceSearchSummary(combining: parts.compactMap { $0 }, resultLimit: query.resultLimit, wasCut: await budget.isExhausted)
    }
}

extension RuntimeEngine.SearchMembersCommand: RuntimeEngineSpanningProgressCommand {
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeMemberSearchBatch) async -> Void)?
    ) async throws -> RuntimeInterfaceSearchSummary {
        let budget = RuntimeSpanningResultBudget(limit: query.resultLimit)
        let parts = try await participants.concurrentResults { participant -> RuntimeInterfaceSearchSummary? in
            var participantQuery = query
            if let imagePaths = query.imagePaths {
                let participantImagePaths = imagePaths.filter(participant.includesImage)
                guard !participantImagePaths.isEmpty else { return nil }
                participantQuery.imagePaths = participantImagePaths
            }
            let forwardBatch: (@Sendable (RuntimeMemberSearchBatch) async -> Void)? = onProgress.map { onProgress in
                { batch in
                    let results = batch.results().filter { participant.includesImage($0.object.imagePath) }
                    let admittedCount = await budget.admit(results.count)
                    guard admittedCount > 0 else { return }
                    await onProgress(RuntimeMemberSearchBatch(Array(results.prefix(admittedCount))))
                }
            }
            let summary = try await participant.dispatch(RuntimeEngine.SearchMembersCommand(query: participantQuery), onProgress: forwardBatch)
            return summary.keepingImages(where: participant.includesImage)
        }
        return RuntimeInterfaceSearchSummary(combining: parts.compactMap { $0 }, resultLimit: query.resultLimit, wasCut: await budget.isExhausted)
    }
}

/// How many results the parts of a search still deliver between them: the
/// query's limit holds for the whole answer, not for each participant.
private actor RuntimeSpanningResultBudget {
    private var remainingCount: Int

    /// Whether some result was held back.
    private(set) var isExhausted = false

    init(limit: Int) {
        remainingCount = max(0, limit)
    }

    /// How many of `count` results may still be delivered.
    func admit(_ count: Int) -> Int {
        let admittedCount = min(count, remainingCount)
        remainingCount -= admittedCount
        if admittedCount < count {
            isExhausted = true
        }
        return admittedCount
    }
}

private extension RuntimeInterfaceSearchSummary {
    /// The summary of the images `isIncluded` accepts. The counts cannot be
    /// split by image and stay as they are: a participant's store holds only
    /// its own images' corpora, built by its own work.
    func keepingImages(where isIncluded: (String) -> Bool) -> RuntimeInterfaceSearchSummary {
        RuntimeInterfaceSearchSummary(
            totalMatchCount: totalMatchCount,
            scannedImagePaths: scannedImagePaths.filter(isIncluded),
            scannedObjectCount: scannedObjectCount,
            isTruncated: isTruncated,
            unbuiltIndexedImagePaths: unbuiltIndexedImagePaths.filter(isIncluded),
            stopReason: stopReason,
            omittedRepeatedMatchCount: omittedRepeatedMatchCount
        )
    }

    /// One summary of `parts`, for a search whose delivered results were held
    /// to `resultLimit` across all of them.
    init(combining parts: [RuntimeInterfaceSearchSummary], resultLimit: Int, wasCut: Bool) {
        let totalMatchCount = parts.map(\.totalMatchCount).reduce(0, +)
        self.init(
            totalMatchCount: totalMatchCount,
            scannedImagePaths: parts.flatMap(\.scannedImagePaths).sorted(),
            scannedObjectCount: parts.map(\.scannedObjectCount).reduce(0, +),
            isTruncated: wasCut || totalMatchCount > resultLimit || parts.contains(where: \.isTruncated),
            unbuiltIndexedImagePaths: parts.flatMap(\.unbuiltIndexedImagePaths).sorted(),
            stopReason: parts.lazy.compactMap(\.stopReason).first,
            omittedRepeatedMatchCount: parts.map(\.omittedRepeatedMatchCount).reduce(0, +)
        )
    }
}

// MARK: - Type relationships

extension RuntimeEngine.TypeRelationshipsCommand: RuntimeEngineSpanningProgressCommand {
    /// The owners walk the shared cache's types first. The requested engine
    /// then walks its own images, given the owners' types as external roots
    /// so it finds what of its own descends from or conforms to them; those
    /// subtrees are grafted onto the owners' trees, and an ancestor its own
    /// images could not resolve is resolved by an owner. Last, the trees are
    /// cut to the query's images, ordered as one engine orders its
    /// candidates and held to the candidate limit.
    ///
    /// The owners are asked without the query's images: a type of those
    /// images can derive from a shared cache type outside them, the very case
    /// the merge is for.
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeEngineEmpty) async -> Void)?
    ) async throws -> [RuntimeRelationshipTree] {
        guard let requestedEngine = participants.requestedEngine else { return [] }
        let owners = participants.owners

        var ownerQuery = query
        ownerQuery.imagePaths = nil
        ownerQuery.externalRoots = nil
        let ownerTrees = try await owners.concurrentResults { owner in
            try await owner.dispatch(RuntimeEngine.TypeRelationshipsCommand(query: ownerQuery), onProgress: nil)
                .filter { owner.includesImage($0.root.imagePath) }
        }
        .flatMap { $0 }

        var requestedQuery = query
        requestedQuery.imagePaths = nil
        if query.relationship != .ancestors {
            let ownerObjects = ownerTrees.flatMap { [$0.root] + $0.nodes.allObjects }
            requestedQuery.externalRoots = Array(OrderedSet(ownerObjects.map(\.strippedOfChildren)))
        }
        let requestedTrees = try await requestedEngine.dispatch(RuntimeEngine.TypeRelationshipsCommand(query: requestedQuery), onProgress: nil)

        var ownTrees: [RuntimeRelationshipTree] = []
        var externalSubtrees: [RuntimeObject: [RuntimeRelationshipNode]] = [:]
        for tree in requestedTrees {
            if requestedEngine.includesImage(tree.root.imagePath) {
                ownTrees.append(tree)
            } else {
                // A subtree under one of the owners' types: only what leads
                // into the requested engine's own images is its to add.
                let ownNodes = tree.nodes.leading(intoImagesWhere: requestedEngine.includesImage)
                guard !ownNodes.isEmpty else { continue }
                externalSubtrees[tree.root, default: []] += ownNodes
            }
        }

        if query.relationship == .ancestors {
            let resolvedTrees = await participants.ownersAncestorTrees(named: ownTrees.flatMap(\.nodes).unresolvedNames)
            ownTrees = ownTrees.map { RuntimeRelationshipTree(root: $0.root, nodes: $0.nodes.resolving(resolvedTrees)) }
        }

        var trees = ownerTrees.map { tree in
            RuntimeRelationshipTree(root: tree.root, nodes: tree.nodes.grafting(externalSubtrees) + (externalSubtrees[tree.root] ?? []))
        }
        trees += ownTrees

        if let imagePaths = query.imagePaths {
            trees = trees.compactMap { tree in
                let nodes = tree.nodes.leading(intoImagesWhere: imagePaths.contains)
                return nodes.isEmpty ? nil : RuntimeRelationshipTree(root: tree.root, nodes: nodes)
            }
        }
        return orderedAndLimited(trees)
    }

    /// The trees as one engine orders its candidates — the types named by the
    /// query itself first, in the order they came, then the rest by name —
    /// and at most the query's candidate limit of them.
    private func orderedAndLimited(_ trees: [RuntimeRelationshipTree]) -> [RuntimeRelationshipTree] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let options: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]
        func isNamedByQuery(_ object: RuntimeObject) -> Bool {
            object.displayName.compare(text, options: options) == .orderedSame
                || String(RuntimeInterfaceTextMatcher.ownTypeName(of: object.displayName)).compare(text, options: options) == .orderedSame
        }
        let exactTrees = trees.filter { isNamedByQuery($0.root) }
        let otherTrees = trees.filter { !isNamedByQuery($0.root) }.sorted { leftTree, rightTree in
            leftTree.root.displayName.localizedCaseInsensitiveCompare(rightTree.root.displayName) == .orderedAscending
        }
        return Array((exactTrees + otherTrees).prefix(max(0, query.candidateLimit)))
    }
}

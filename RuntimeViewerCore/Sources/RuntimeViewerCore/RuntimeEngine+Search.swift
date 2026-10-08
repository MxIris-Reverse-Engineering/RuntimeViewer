import Foundation
import RuntimeViewerCommunication

// MARK: - Public API

extension RuntimeEngine {
    /// Builds — or joins the build of, or returns the already built — corpus
    /// of `imagePath`: every object's interface printed once with
    /// `transformer` and marked for every combination of the Generation
    /// Options — searches read it under the options they carry — plus the
    /// members it declares.
    /// Runs in the process that owns the image; over a connection only the
    /// progress and the summary travel. Cancelling the calling task withdraws
    /// this caller's subscription to the build, not the build itself, unless
    /// no one else is waiting for it. Over a connection the withdrawal
    /// reaches the serving process as a `cancelRequest`, and the caller
    /// returns without waiting for it (see
    /// `RuntimeEngineProgressCommand.cancelsAcrossConnections`).
    ///
    /// `isPrioritized` puts the image at the front of the build queue — an
    /// image the user just opened, say. The image being built at the moment
    /// still finishes first.
    ///
    /// Throws `CancellationError` when the build was given up — by this
    /// caller, or by the store for every subscriber — in whichever process
    /// it ran, and `RuntimeInterfaceCorpusBuildError` when there was nothing
    /// to build.
    public func buildInterfaceCorpus(
        for imagePath: String,
        transformer: Transformer.Configuration,
        isPrioritized: Bool = false,
        onProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void = { _ in }
    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
        let outcome = try await dispatch(BuildInterfaceCorpusCommand(imagePath: imagePath, transformer: transformer, isPrioritized: isPrioritized), onProgress: onProgress)
        switch outcome {
        case .built(let summary):
            return summary
        case .cancelled:
            throw CancellationError()
        case .imageNotIndexed:
            throw RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: imagePath)
        }
    }

    /// Moves `imagePath`, already queued, to the front of the build queue
    /// without adding a subscription to its build — for a caller that has
    /// asked for the image before. Does nothing when the image is not queued:
    /// built, being built, or never asked for.
    public func prioritizeInterfaceCorpus(for imagePath: String) async throws {
        _ = try await dispatch(PrioritizeInterfaceCorpusCommand(imagePath: imagePath))
    }

    /// Text search over every built corpus. Matches arrive through
    /// `onProgress` one image at a time, up to `query.resultLimit` of them;
    /// the summary's total keeps counting past that. Cancelling the calling
    /// task stops the search, in the serving process too, and no batch
    /// reaches `onProgress` afterwards.
    public func searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        onProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        try await dispatch(SearchInterfacesCommand(query: query), onProgress: onProgress)
    }

    /// Member-name search over every built corpus, same delivery and
    /// cancellation as `searchInterfaces`.
    public func searchMembers(
        _ query: RuntimeMemberSearchQuery,
        onProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        try await dispatch(SearchMembersCommand(query: query), onProgress: onProgress)
    }

    /// Ancestor, descendant or conformer trees for every indexed type whose
    /// name matches the query, holding only the types of the query's images
    /// when it names some. Needs no corpus: the relationship tables are built
    /// when an image is indexed. Over a connection, cancelling the calling
    /// task returns it at once and cancels the task answering the query in
    /// the serving process.
    public func typeRelationships(_ query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree] {
        try await dispatch(TypeRelationshipsCommand(query: query))
    }

    /// Where every image's corpus stands, plus the resident budget.
    public func interfaceCorpusCoverage() async throws -> RuntimeInterfaceCorpusCoverage {
        try await dispatch(InterfaceCorpusCoverageCommand())
    }

    /// Every image with both sections built — the images a corpus can be
    /// built for. The same predicate as `isImageIndexed(path:)`, answered for
    /// all images at once.
    public func indexedImagePathList() async throws -> [String] {
        try await dispatch(IndexedImagePathsCommand())
    }

    /// Drops one image's corpus, or every corpus when `imagePath` is `nil`.
    /// A build under way for it is cancelled.
    public func evictInterfaceCorpus(for imagePath: String?) async throws {
        _ = try await dispatch(EvictInterfaceCorpusCommand(imagePath: imagePath))
    }

    /// Sets the resident budget of the corpus store; corpora least recently
    /// searched are evicted until the total fits.
    public func setInterfaceCorpusResidentByteLimit(_ byteLimit: Int) async throws {
        _ = try await dispatch(SetInterfaceCorpusResidentByteLimitCommand(byteLimit: byteLimit))
    }
}

// MARK: - Local arms

extension RuntimeEngine {
    /// The cancellation the store ends a build with comes back as
    /// `.cancelled`, a value, so it survives the trip to a caller in another
    /// process; see `RuntimeInterfaceCorpusBuildOutcome`.
    ///
    /// A corpus is printed from the sections the engine already built; asking
    /// for it never indexes an image. Indexing here would bypass both the
    /// foreground and the background schedulers, an image that is not loaded
    /// would fail and stay failed, and for a path dyld does not know, the
    /// section factories' file-name fallback would index a same-named image
    /// under that path. An image without both sections is `.imageNotIndexed`
    /// and leaves the store untouched; it is asked for again once indexed.
    func _buildInterfaceCorpus(
        for imagePath: String,
        transformer: Transformer.Configuration,
        isPrioritized: Bool,
        reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void
    ) async throws -> RuntimeInterfaceCorpusBuildOutcome {
        let canonical = DyldUtilities.patchImagePathForDyld(imagePath)
        guard await _isImageIndexed(path: canonical) else { return .imageNotIndexed }
        do {
            let summary = try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
            return .built(summary)
        } catch is CancellationError {
            return .cancelled
        }
    }

    func _prioritizeInterfaceCorpus(for imagePath: String) async {
        await interfaceCorpusStore.prioritize(imagePath: DyldUtilities.patchImagePathForDyld(imagePath))
    }

    func _searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        reportProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        var query = query
        query.imagePaths = query.imagePaths.map { Set($0.map(DyldUtilities.patchImagePathForDyld)) }
        return try await interfaceCorpusStore.searchInterfaces(query, indexedImagePaths: await indexedImagePaths(), onProgress: reportProgress)
    }

    func _searchMembers(
        _ query: RuntimeMemberSearchQuery,
        reportProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        var query = query
        query.imagePaths = query.imagePaths.map { Set($0.map(DyldUtilities.patchImagePathForDyld)) }
        return try await interfaceCorpusStore.searchMembers(query, indexedImagePaths: await indexedImagePaths(), onProgress: reportProgress)
    }

    func _typeRelationships(_ query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree] {
        var query = query
        query.imagePaths = query.imagePaths.map { Set($0.map(DyldUtilities.patchImagePathForDyld)) }
        return try await typeRelationshipsResolver.trees(for: query)
    }

    func _interfaceCorpusCoverage() async -> RuntimeInterfaceCorpusCoverage {
        await interfaceCorpusStore.coverage(indexedImagePaths: await indexedImagePaths())
    }

    func _evictInterfaceCorpus(for imagePath: String?) async {
        if let imagePath {
            await interfaceCorpusStore.evict(imagePath: DyldUtilities.patchImagePathForDyld(imagePath))
        } else {
            await interfaceCorpusStore.evictAll()
        }
    }

    func _setInterfaceCorpusResidentByteLimit(_ byteLimit: Int) async {
        await interfaceCorpusStore.setResidentByteLimit(byteLimit)
    }

    /// Every image with both sections cached — the same predicate as
    /// `isImageIndexed(path:)`, over all images at once.
    func indexedImagePaths() async -> Set<String> {
        let objcImagePaths = await objcSectionFactory.cachedImagePaths
        let swiftImagePaths = await swiftSectionFactory.cachedImagePaths
        return objcImagePaths.intersection(swiftImagePaths)
    }
}

// MARK: - Corpus building

extension RuntimeEngine: RuntimeInterfaceCorpusBuilding {
    /// The sections already built, never new ones — see
    /// `_buildInterfaceCorpus`. Missing ones mean the engine let go of them
    /// while the build waited for its turn.
    func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
        guard let objcSection = await objcSectionFactory.existingSection(for: imagePath),
              let swiftSection = await swiftSectionFactory.existingSection(for: imagePath)
        else {
            throw RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: imagePath)
        }
        let objcObjects = try await objcSection.allObjects()
        let swiftObjects = try await swiftSection.allObjects()
        return (objcObjects + swiftObjects).flatMap(\.corpusFamily)
    }

    /// A Swift family goes to its section whole, which takes the nested
    /// types' definitions out of their parent's print. Nothing nests in
    /// Objective-C, so each object of such a family is printed on its own.
    func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome] {
        guard let root = family.first else { return [] }
        switch root.kind {
        case .swift:
            guard let section = await swiftSectionFactory.existingSection(for: root.imagePath) else {
                return family.map { _ in .empty }
            }
            return try await section.corpusPrints(of: family, transformer: transformer)
        case .objc, .c:
            guard let section = await objcSectionFactory.existingSection(for: root.imagePath) else {
                return family.map { _ in .empty }
            }
            var outcomes: [RuntimeInterfaceCorpusPrintOutcome] = []
            outcomes.reserveCapacity(family.count)
            for object in family {
                try Task.checkCancellation()
                do {
                    if let objectPrint = try await section.corpusPrint(for: object, transformer: transformer) {
                        outcomes.append(.printed(objectPrint))
                    } else {
                        outcomes.append(.empty)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcomes.append(.failed("\(error)"))
                }
            }
            return outcomes
        }
    }
}

// MARK: - Commands

extension RuntimeEngine {
    /// Answers with an outcome rather than a bare summary: the command is as
    /// new as the corpus, so its reply could take the shape a cancellation
    /// needs to cross a connection.
    struct BuildInterfaceCorpusCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeInterfaceCorpusBuildOutcome
        typealias Progress = RuntimeInterfaceCorpusBuildProgress
        let imagePath: String
        let transformer: Transformer.Configuration
        let isPrioritized: Bool
        static var commandName: String { CommandName.buildInterfaceCorpus.commandName }
        static var cancelsAcrossConnections: Bool { true }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void) async throws -> RuntimeInterfaceCorpusBuildOutcome {
            try await engine._buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized, reportProgress: reportProgress)
        }
    }

    struct PrioritizeInterfaceCorpusCommand: RuntimeEngineCommand {
        let imagePath: String
        static var commandName: String { CommandName.prioritizeInterfaceCorpus.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._prioritizeInterfaceCorpus(for: imagePath)
            return RuntimeEngineEmpty()
        }
    }

    struct SearchInterfacesCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeInterfaceSearchSummary
        typealias Progress = [RuntimeInterfaceSearchMatch]
        let query: RuntimeInterfaceSearchQuery
        static var commandName: String { CommandName.searchInterfaces.commandName }
        static var cancelsAcrossConnections: Bool { true }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
            try await engine._searchInterfaces(query, reportProgress: reportProgress)
        }
    }

    struct SearchMembersCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeInterfaceSearchSummary
        typealias Progress = [RuntimeMemberMatch]
        let query: RuntimeMemberSearchQuery
        static var commandName: String { CommandName.searchMembers.commandName }
        static var cancelsAcrossConnections: Bool { true }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
            try await engine._searchMembers(query, reportProgress: reportProgress)
        }
    }

    /// A progress command that reports no progress: only so its caller can
    /// withdraw it from the serving process. The command is as new as
    /// `cancelRequest`, so changing its shape cost no peer anything.
    struct TypeRelationshipsCommand: RuntimeEngineProgressCommand {
        typealias Response = [RuntimeRelationshipTree]
        typealias Progress = RuntimeEngineEmpty
        let query: RuntimeTypeRelationshipsQuery
        static var commandName: String { CommandName.typeRelationships.commandName }
        static var cancelsAcrossConnections: Bool { true }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeEngineEmpty) async -> Void) async throws -> [RuntimeRelationshipTree] {
            try await engine._typeRelationships(query)
        }
    }

    struct IndexedImagePathsCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.indexedImagePaths.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            await engine.indexedImagePaths().sorted()
        }
    }

    struct InterfaceCorpusCoverageCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.interfaceCorpusCoverage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeInterfaceCorpusCoverage {
            await engine._interfaceCorpusCoverage()
        }
    }

    struct EvictInterfaceCorpusCommand: RuntimeEngineCommand {
        let imagePath: String?
        static var commandName: String { CommandName.evictInterfaceCorpus.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._evictInterfaceCorpus(for: imagePath)
            return RuntimeEngineEmpty()
        }
    }

    struct SetInterfaceCorpusResidentByteLimitCommand: RuntimeEngineCommand {
        let byteLimit: Int
        static var commandName: String { CommandName.setInterfaceCorpusResidentByteLimit.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._setInterfaceCorpusResidentByteLimit(byteLimit)
            return RuntimeEngineEmpty()
        }
    }
}

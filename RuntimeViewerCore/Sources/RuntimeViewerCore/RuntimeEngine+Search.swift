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
    /// no one else is waiting for it.
    ///
    /// `isPrioritized` puts the image at the front of the build queue — an
    /// image the user just opened, say. The image being built at the moment
    /// still finishes first.
    public func buildInterfaceCorpus(
        for imagePath: String,
        transformer: Transformer.Configuration,
        isPrioritized: Bool = false,
        onProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void = { _ in }
    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
        try await dispatch(BuildInterfaceCorpusRequest(imagePath: imagePath, transformer: transformer, isPrioritized: isPrioritized), onProgress: onProgress)
    }

    /// Moves `imagePath`, already queued, to the front of the build queue
    /// without adding a subscription to its build — for a caller that has
    /// asked for the image before. Does nothing when the image is not queued:
    /// built, being built, or never asked for.
    public func prioritizeInterfaceCorpus(for imagePath: String) async throws {
        _ = try await dispatch(PrioritizeInterfaceCorpusRequest(imagePath: imagePath))
    }

    /// Text search over every built corpus. Matches arrive through
    /// `onProgress` one image at a time, up to `query.resultLimit` of them;
    /// the summary's total keeps counting past that.
    public func searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        onProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        try await dispatch(SearchInterfacesRequest(query: query), onProgress: onProgress)
    }

    /// Member-name search over every built corpus, same delivery as
    /// `searchInterfaces`.
    public func searchMembers(
        _ query: RuntimeMemberSearchQuery,
        onProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        try await dispatch(SearchMembersRequest(query: query), onProgress: onProgress)
    }

    /// Ancestor, descendant or conformer trees for every indexed type whose
    /// name matches the query, holding only the types of the query's images
    /// when it names some. Needs no corpus: the relationship tables are built
    /// when an image is indexed.
    public func typeRelationships(_ query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree] {
        try await dispatch(TypeRelationshipsRequest(query: query))
    }

    /// Where every image's corpus stands, plus the resident budget.
    public func interfaceCorpusCoverage() async throws -> RuntimeInterfaceCorpusCoverage {
        try await dispatch(InterfaceCorpusCoverageRequest())
    }

    /// Every image with both sections built — the images a corpus can be
    /// built for. The same predicate as `isImageIndexed(path:)`, answered for
    /// all images at once.
    public func indexedImagePathList() async throws -> [String] {
        try await dispatch(IndexedImagePathsRequest())
    }

    /// Drops one image's corpus, or every corpus when `imagePath` is `nil`.
    /// A build under way for it is cancelled.
    public func evictInterfaceCorpus(for imagePath: String?) async throws {
        _ = try await dispatch(EvictInterfaceCorpusRequest(imagePath: imagePath))
    }

    /// Sets the resident budget of the corpus store; corpora least recently
    /// searched are evicted until the total fits.
    public func setInterfaceCorpusResidentByteLimit(_ byteLimit: Int) async throws {
        _ = try await dispatch(SetInterfaceCorpusResidentByteLimitRequest(byteLimit: byteLimit))
    }
}

// MARK: - Local arms

extension RuntimeEngine {
    func _buildInterfaceCorpus(
        for imagePath: String,
        transformer: Transformer.Configuration,
        isPrioritized: Bool,
        reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void
    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
        let canonical = DyldUtilities.patchImagePathForDyld(imagePath)
        return try await interfaceCorpusStore.build(imagePath: canonical, transformer: transformer, isPrioritized: isPrioritized, onProgress: reportProgress)
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

    func _typeRelationships(_ query: RuntimeTypeRelationshipsQuery) async -> [RuntimeRelationshipTree] {
        var query = query
        query.imagePaths = query.imagePaths.map { Set($0.map(DyldUtilities.patchImagePathForDyld)) }
        return await typeRelationshipsResolver.trees(for: query)
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
    func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
        try await _objects(in: imagePath).flatMap(\.corpusFamily)
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

// MARK: - Requests

extension RuntimeEngine {
    struct BuildInterfaceCorpusRequest: RuntimeEngineProgressRequest {
        typealias Response = RuntimeInterfaceCorpusBuildSummary
        typealias Progress = RuntimeInterfaceCorpusBuildProgress
        let imagePath: String
        let transformer: Transformer.Configuration
        let isPrioritized: Bool
        static var commandName: String { CommandNames.buildInterfaceCorpus.commandName }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void) async throws -> RuntimeInterfaceCorpusBuildSummary {
            try await engine._buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized, reportProgress: reportProgress)
        }
    }

    struct PrioritizeInterfaceCorpusRequest: RuntimeEngineRequest {
        let imagePath: String
        static var commandName: String { CommandNames.prioritizeInterfaceCorpus.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._prioritizeInterfaceCorpus(for: imagePath)
            return RuntimeEngineEmpty()
        }
    }

    struct SearchInterfacesRequest: RuntimeEngineProgressRequest {
        typealias Response = RuntimeInterfaceSearchSummary
        typealias Progress = [RuntimeInterfaceSearchMatch]
        let query: RuntimeInterfaceSearchQuery
        static var commandName: String { CommandNames.searchInterfaces.commandName }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
            try await engine._searchInterfaces(query, reportProgress: reportProgress)
        }
    }

    struct SearchMembersRequest: RuntimeEngineProgressRequest {
        typealias Response = RuntimeInterfaceSearchSummary
        typealias Progress = [RuntimeMemberMatch]
        let query: RuntimeMemberSearchQuery
        static var commandName: String { CommandNames.searchMembers.commandName }
        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable ([RuntimeMemberMatch]) async -> Void) async throws -> RuntimeInterfaceSearchSummary {
            try await engine._searchMembers(query, reportProgress: reportProgress)
        }
    }

    struct TypeRelationshipsRequest: RuntimeEngineRequest {
        let query: RuntimeTypeRelationshipsQuery
        static var commandName: String { CommandNames.typeRelationships.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeRelationshipTree] {
            await engine._typeRelationships(query)
        }
    }

    struct IndexedImagePathsRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.indexedImagePaths.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            await engine.indexedImagePaths().sorted()
        }
    }

    struct InterfaceCorpusCoverageRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.interfaceCorpusCoverage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeInterfaceCorpusCoverage {
            await engine._interfaceCorpusCoverage()
        }
    }

    struct EvictInterfaceCorpusRequest: RuntimeEngineRequest {
        let imagePath: String?
        static var commandName: String { CommandNames.evictInterfaceCorpus.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._evictInterfaceCorpus(for: imagePath)
            return RuntimeEngineEmpty()
        }
    }

    struct SetInterfaceCorpusResidentByteLimitRequest: RuntimeEngineRequest {
        let byteLimit: Int
        static var commandName: String { CommandNames.setInterfaceCorpusResidentByteLimit.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine._setInterfaceCorpusResidentByteLimit(byteLimit)
            return RuntimeEngineEmpty()
        }
    }
}

import Foundation
import FoundationToolbox
import MachO
import RuntimeViewerCore
import CrossReferenceAnalysis

/// Answers the cross-reference commands in the process that serves the
/// engine, against that process's images.
///
/// Callees decode one function. Callers and a type's references are found in
/// the images the engine has indexed: those that cannot reference the subject
/// are filtered out first — by the symbols they import, the images they link
/// and the selectors they reference — and the rest are read a few at a time
/// on the session's queue. Each is either scanned for the subject alone or,
/// when the options ask for it, read from the image's prepared index, which
/// is prepared now if it is not ready (`prepare(imageAt:options:reportProgress:)`
/// prepares one ahead of the queries). No other image's code is read.
struct CrossReferenceQuery {
    let engine: RuntimeEngine
    let session: CrossReferenceSession
    /// The paths of the images the engine has indexed.
    let indexedImagePaths: @Sendable () async throws -> [String]

    /// `indexedImagePaths` stands in for the engine's own list, which is what
    /// the commands read.
    init(engine: RuntimeEngine, session: CrossReferenceSession, indexedImagePaths: (@Sendable () async throws -> [String])? = nil) {
        self.engine = engine
        self.session = session
        self.indexedImagePaths = indexedImagePaths ?? { try await engine.indexedImagePathList() }
    }

    // MARK: - Callees

    func callees(of subject: RuntimeCrossReferenceSubject, options: RuntimeCrossReferenceQueryOptions) async throws -> RuntimeCrossReferenceQueryResult {
        if case .selector(let selector) = subject {
            throw RuntimeCrossReferenceError.selectorHasNoCallees(selector)
        }
        let (analyzer, generation) = try session.currentAnalyzer()
        let resolvedSubject = try await resolve(subject, with: analyzer)
        var builder = FunctionReferenceBuilder(analyzer: analyzer)
        var references: [RuntimeCrossReference] = []

        for subjectFunction in resolvedSubject.functions {
            let referencingFunction = builder.reference(for: subjectFunction.function, member: subjectFunction.member)
            let sendingMethods = ObjectiveCMethodName.all(of: subjectFunction.function)
            let madeReferences = analyzer.references(madeBy: subjectFunction.function)
            let targetImageIndices = Set(madeReferences.compactMap { reference -> Int? in
                guard case .function(let location) = reference.target else { return nil }
                return location.imageIndex
            })
            for reference in madeReferences {
                if reference.isRuntimeHelperCall, !options.includesRuntimeHelperCalls { continue }
                let converted = calleeReferences(
                    reference,
                    referencingFunction: referencingFunction,
                    sendingMethods: sendingMethods,
                    analyzer: analyzer,
                    builder: &builder
                )
                references.append(contentsOf: converted.filter { Self.receiverMatches($0, options: options) })
            }
            session.noteFunctionTables(ofImagesAt: targetImageIndices.union([subjectFunction.function.location.imageIndex]), generation: generation)
        }

        if let resultLimit = options.resultLimit, references.count > resultLimit {
            return RuntimeCrossReferenceQueryResult(references: Array(references.prefix(max(0, resultLimit))), isComplete: false)
        }
        return RuntimeCrossReferenceQueryResult(references: references, isComplete: true)
    }

    /// What the wire makes of one reference: one, or one per type for a
    /// mangled name, which names several — `[SwiftUI.Text]` uses `Array` and
    /// `Text`.
    private func calleeReferences(
        _ reference: CodeReference,
        referencingFunction: RuntimeFunctionReference,
        sendingMethods: [ObjectiveCMethodName],
        analyzer: CrossReferenceAnalyzer,
        builder: inout FunctionReferenceBuilder
    ) -> [RuntimeCrossReference] {
        func make(_ kind: RuntimeCrossReferenceKind, _ target: RuntimeCrossReferenceTarget, _ precision: RuntimeCrossReferencePrecision) -> RuntimeCrossReference {
            RuntimeCrossReference(
                referencingFunction: referencingFunction,
                instructionAddress: reference.instructionAddress,
                kind: kind,
                target: target,
                precision: precision,
                isRuntimeHelperCall: reference.isRuntimeHelperCall
            )
        }
        let branchKind: RuntimeCrossReferenceKind = reference.kind == .tailCall ? .tailCall : .call
        switch reference.target {
        case .function(let location):
            if let function = analyzer.function(containing: location), function.location == location {
                return [make(branchKind, .function(builder.reference(for: function)), .exact)]
            }
            return [make(branchKind, .function(builder.unnamedReference(at: location)), .exact)]
        case .importedSymbol(let name):
            return [make(branchKind, .importedSymbol(name: name), .exact)]
        case .messageSend(let selector, let receiver):
            let receiverClassName = ObjectiveCSendMatching.receiverClassName(of: receiver, isSuperSend: false, from: sendingMethods)
            return [make(.messageSend, .selector(name: selector, receiverClassName: receiverClassName), receiverClassName == nil ? .matchedBySelector : .exact)]
        case .superMessageSend(let selector, _):
            return [make(.superMessageSend, .selector(name: selector, receiverClassName: nil), .exact)]
        case .objectiveCClass(let name, _):
            return [make(.typeReference, .type(name: CrossReferenceNaming.displayName(forClassName: name), object: nil), .exact)]
        case .swiftType(let descriptor):
            guard let key = analyzer.swiftTypeIdentity(ofDescriptorAt: descriptor)?.key else { return [] }
            return [make(.typeReference, .type(name: CrossReferenceNaming.displayName(forTypeKey: key), object: nil), .exact)]
        case .swiftTypeName(let name):
            var seenKeys = Set<String>()
            return analyzer.swiftTypeKeys(in: name).filter { seenKeys.insert($0).inserted }.map { key in
                make(.typeReference, .type(name: CrossReferenceNaming.displayName(forTypeKey: key), object: nil), .exact)
            }
        case .indirect(let evidence):
            // No candidates are listed yet: the target is one of the
            // functions the evidence could lead to.
            return [make(.indirectCall, .indirect(tableOffset: evidence.tableOffset, pointerAuthenticationConstant: evidence.pointerAuthenticationConstant), .candidate)]
        case .unrecognized(let address):
            return [make(branchKind, .unrecognizedCode(address: address), .exact)]
        }
    }

    // MARK: - Callers

    func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult {
        let startTime = Date()
        let (analyzer, generation) = try session.currentAnalyzer()
        let indexedImages = try await indexedImageIndices(in: analyzer)
        let resolvedSubject = try await resolve(subject, with: analyzer)
        // Finding the subject kept its image's function table.
        session.noteFunctionTables(ofImagesAt: resolvedSubject.functions.map(\.function.location.imageIndex), generation: generation)
        let keys = resolvedSubject.callerKeys
        let candidates = try candidateImages(for: resolvedSubject, in: scope, among: indexedImages, analyzer: analyzer)
        var builder = FunctionReferenceBuilder(analyzer: analyzer)
        var subjectFunctionsByLocation: [CodeLocation: RuntimeFunctionReference] = [:]
        for subjectFunction in resolvedSubject.functions where subjectFunctionsByLocation[subjectFunction.function.location] == nil {
            subjectFunctionsByLocation[subjectFunction.function.location] = builder.reference(for: subjectFunction.function, member: subjectFunction.member)
        }
        let matcher = CallerMatcher(subject: resolvedSubject, subjectFunctionsByLocation: subjectFunctionsByLocation, options: options)
        let (result, cachedImageCount) = try await scan(
            candidates,
            for: .references(keys),
            generation: generation,
            analyzer: analyzer,
            options: options,
            reportProgress: reportProgress,
            find: { analyzer.references(to: keys, inImageAt: $0) },
            findInIndex: { $0.references(to: keys) },
            convert: { matcher.callerReferences(from: $0, analyzer: analyzer) }
        )
        CrossReferenceQueryLog.answered(
            "Callers",
            candidateCount: candidates.count,
            cachedCount: cachedImageCount,
            referenceCount: result.references.count,
            isComplete: result.isComplete,
            elapsed: Date().timeIntervalSince(startTime)
        )
        return result
    }

    /// The images a scope asks about that can reference the subject, among
    /// the indexed ones.
    func candidateImages(for subject: ResolvedSubject, in scope: RuntimeCrossReferenceScope, among indexedImages: Set<Int>, analyzer: CrossReferenceAnalyzer) throws -> [Int] {
        switch scope {
        case .image(let path):
            return [try Self.indexedImageIndex(forPath: path, among: indexedImages, in: analyzer)]
        case .indexedImages:
            let indexedImages = indexedImages.sorted()
            var candidates = Set<Int>()
            for subjectFunction in subject.functions {
                // A function its own image can always reach; another image
                // through a C or Objective-C name it imports, or — for a
                // Swift name, which no shared cache image keeps among its
                // imports — by linking the function's image.
                candidates.formUnion(analyzer.imageIndices(
                    callingFunctionAt: subjectFunction.function.location,
                    symbolNames: subjectFunction.symbolNames,
                    among: indexedImages
                ))
            }
            for selector in subject.selectors {
                candidates.formUnion(analyzer.imageIndices(referencingSelector: selector, among: indexedImages))
            }
            return candidates.sorted()
        }
    }

    /// The analyzer's indices of the images the engine has indexed — the only
    /// images a scan reads.
    private func indexedImageIndices(in analyzer: CrossReferenceAnalyzer) async throws -> Set<Int> {
        Set(try await indexedImagePaths().compactMap { Self.imageIndex(forPath: $0, in: analyzer) })
    }

    /// The analyzer's index for the image a scope names, which the engine
    /// must have indexed.
    static func indexedImageIndex(forPath path: String, among indexedImages: Set<Int>, in analyzer: CrossReferenceAnalyzer) throws -> Int {
        guard let imageIndex = imageIndex(forPath: path, in: analyzer) else {
            throw RuntimeCrossReferenceError.imageNotFound(path: path)
        }
        guard indexedImages.contains(imageIndex) else {
            throw RuntimeCrossReferenceError.imageNotIndexed(path: path)
        }
        return imageIndex
    }

    // MARK: - Type references

    func typeReferences(
        to object: RuntimeObject,
        in scope: RuntimeCrossReferenceScope,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult {
        let startTime = Date()
        let (analyzer, generation) = try session.currentAnalyzer()
        let indexedImages = try await indexedImageIndices(in: analyzer)
        let type = try resolveType(object, with: analyzer)
        let candidates: [Int]
        switch scope {
        case .image(let path):
            candidates = [try Self.indexedImageIndex(forPath: path, among: indexedImages, in: analyzer)]
        case .indexedImages:
            candidates = type.candidateImages(among: indexedImages.sorted(), analyzer: analyzer)
        }
        // Who the type is, without its children — nested types and
        // specializations, which a reference to it does not need and would
        // carry once per reference.
        let targetObject = RuntimeObject(
            name: object.name,
            displayName: object.displayName,
            kind: object.kind,
            imagePath: object.imagePath,
            children: [],
            properties: object.properties,
            privateDeclarations: object.privateDeclarations
        )
        let target = RuntimeCrossReferenceTarget.type(name: object.displayName, object: targetObject)
        let (result, cachedImageCount) = try await scan(
            candidates,
            for: type.scanKey,
            generation: generation,
            analyzer: analyzer,
            options: options,
            reportProgress: reportProgress,
            find: { type.references(inImageAt: $0, analyzer: analyzer) },
            findInIndex: { type.references(in: $0, analyzer: analyzer) },
            convert: { TypeReferenceConversion.references(from: $0, to: target, analyzer: analyzer) }
        )
        CrossReferenceQueryLog.answered(
            "Type references",
            candidateCount: candidates.count,
            cachedCount: cachedImageCount,
            referenceCount: result.references.count,
            isComplete: result.isComplete,
            elapsed: Date().timeIntervalSince(startTime)
        )
        return result
    }

    /// A type a query asks about, as the analysis tells its references.
    struct ResolvedType: Sendable {
        enum Identity: Sendable {
            /// A class, by where its class object lies: a name alone can be
            /// defined by the macOS and the Mac Catalyst variant of a
            /// framework alike.
            case objectiveCClass(name: String, location: CodeLocation)
            /// A Swift struct, enum or class — a class also as the
            /// Objective-C class it is.
            case swiftType(SwiftTypeIdentity)
        }

        let identity: Identity

        var scanKey: CrossReferenceScanKey {
            switch identity {
            case .objectiveCClass(_, let location):
                return .objectiveCClass(location)
            case .swiftType(let identity):
                return .swiftType(identity.descriptorLocation)
            }
        }

        func references(inImageAt imageIndex: Int, analyzer: CrossReferenceAnalyzer) -> [CodeReference] {
            switch identity {
            case .objectiveCClass(let name, let location):
                return analyzer.references(to: [.objectiveCClass(name)], inImageAt: imageIndex).filter {
                    if case .objectiveCClass(_, location) = $0.target { return true }
                    return false
                }
            case .swiftType(let identity):
                return analyzer.references(toSwiftType: identity, inImageAt: imageIndex)
            }
        }

        /// What ``references(inImageAt:analyzer:)`` finds, read from the
        /// image's prepared index.
        func references(in index: CodeReferenceIndex, analyzer: CrossReferenceAnalyzer) -> [CodeReference] {
            switch identity {
            case .objectiveCClass(let name, let location):
                return index.references(to: [.objectiveCClass(name)]).filter {
                    if case .objectiveCClass(_, location) = $0.target { return true }
                    return false
                }
            case .swiftType(let identity):
                return analyzer.references(toSwiftType: identity, in: index)
            }
        }

        func candidateImages(among candidates: some Sequence<Int>, analyzer: CrossReferenceAnalyzer) -> [Int] {
            switch identity {
            case .objectiveCClass(_, let location):
                return analyzer.imageIndices(referencingObjectiveCClassAt: location, among: candidates)
            case .swiftType(let identity):
                return analyzer.imageIndices(referencingSwiftType: identity, among: candidates)
            }
        }
    }

    /// The type `object` is: an Objective-C class by its runtime name, a
    /// Swift type by its mangling — the name Runtime Viewer gives both — in
    /// the image that defines it.
    func resolveType(_ object: RuntimeObject, with analyzer: CrossReferenceAnalyzer) throws -> ResolvedType {
        guard let imageIndex = Self.imageIndex(forPath: object.imagePath, in: analyzer) else {
            throw RuntimeCrossReferenceError.imageNotFound(path: object.imagePath)
        }
        let notFound = RuntimeCrossReferenceError.typeNotFound(objectName: object.displayName)
        switch object.kind {
        case .objc(.type(.class)):
            guard let location = analyzer.objectiveCClassLocations(named: object.name, inImageAt: imageIndex).first else { throw notFound }
            return ResolvedType(identity: .objectiveCClass(name: object.name, location: location))
        case .swift(.type(.struct)), .swift(.type(.enum)), .swift(.type(.class)):
            guard let location = analyzer.swiftTypeDescriptorLocations(withKey: object.name, inImageAt: imageIndex).first,
                  let identity = analyzer.swiftTypeIdentity(ofDescriptorAt: location)
            else { throw notFound }
            return ResolvedType(identity: .swiftType(identity))
        default:
            throw notFound
        }
    }

    // MARK: - Preparation

    /// Prepares the image's index ahead of the queries that will read it —
    /// or finds it kept, or joins the preparation under way — and keeps it
    /// within `options.residentByteLimit`. The image must be indexed.
    func prepare(
        imageAt path: String,
        options: RuntimeCrossReferencePreparationOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferencePreparationProgress) async -> Void
    ) async throws -> RuntimeCrossReferencePreparation {
        if let maximumConcurrentScans = options.maximumConcurrentScans {
            session.setMaximumConcurrentScans(maximumConcurrentScans)
        }
        session.setPreparedByteLimit(options.residentByteLimit)
        let (analyzer, generation) = try session.currentAnalyzer()
        let imageIndex = try Self.indexedImageIndex(forPath: path, among: try await indexedImageIndices(in: analyzer), in: analyzer)
        let index = try await session.preparedIndex(ofImageAt: imageIndex, generation: generation, isPrioritized: options.isPrioritized, reportProgress: reportProgress) { shouldContinue in
            analyzer.referenceIndex(ofImageAt: imageIndex, reportingProgress: shouldContinue)
        }
        // Building the index kept the image's function table.
        session.noteFunctionTables(ofImagesAt: [imageIndex], generation: generation)
        return RuntimeCrossReferencePreparation(referenceCount: index.referenceCount, byteCount: index.approximateByteCount)
    }

    /// Sets the most bytes of prepared indexes the session keeps; zero drops
    /// them all.
    func setPreparedByteLimit(_ byteLimit: Int) {
        session.setPreparedByteLimit(byteLimit)
    }

    // MARK: - Scanning

    /// Reads `candidates` for what `find` keeps, and gathers what `convert`
    /// makes of it, reporting after each image and stopping at the limit.
    ///
    /// When the options ask for prepared indexes, each image is read from its
    /// index — `findInIndex` — prepared now, ahead of those waiting, when it
    /// is not ready. Otherwise the images an earlier scan for `scanKey`
    /// covered come first, from the session, and the rest are scanned on the
    /// session's queue.
    private func scan(
        _ candidates: [Int],
        for scanKey: CrossReferenceScanKey,
        generation: Int,
        analyzer: CrossReferenceAnalyzer,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void,
        find: @escaping @Sendable (Int) -> [CodeReference],
        findInIndex: @escaping @Sendable (CodeReferenceIndex) -> [CodeReference],
        convert: @escaping @Sendable ([CodeReference]) -> [RuntimeCrossReference]
    ) async throws -> (result: RuntimeCrossReferenceQueryResult, cachedImageCount: Int) {
        if let maximumConcurrentScans = options.maximumConcurrentScans {
            session.setMaximumConcurrentScans(maximumConcurrentScans)
        }
        let usesPreparedIndexes = options.preparedIndexByteLimit != nil
        if let preparedIndexByteLimit = options.preparedIndexByteLimit {
            session.setPreparedByteLimit(preparedIndexByteLimit)
        }
        var collector = ReferenceCollector(totalImageCount: candidates.count, resultLimit: options.resultLimit)

        // What earlier scans for the same subject found is reported first, in
        // one event. Prepared indexes answer every subject and need none of it.
        let scanned = usesPreparedIndexes ? [:] : session.scannedReferences(for: scanKey, generation: generation)
        let remainingCandidates = candidates.filter { scanned[$0] == nil }
        let cachedImageIndices = candidates.filter { scanned[$0] != nil }
        if !cachedImageIndices.isEmpty {
            let cachedReferences = cachedImageIndices.map { imageIndex in
                (imageIndex: imageIndex, references: convert(scanned[imageIndex] ?? []))
            }
            let report = collector.add(cachedReferences)
            await reportProgress(report)
        }

        if !collector.isFull, !remainingCandidates.isEmpty {
            // As many images handed to the session's queue as it scans at
            // once: a cancelled query leaves no more than that to finish.
            let width = session.maximumConcurrentScans
            try await withThrowingTaskGroup(of: (Int, [CodeReference], [RuntimeCrossReference]).self) { group in
                var nextCandidate = remainingCandidates.makeIterator()
                func addNextScan() {
                    guard let imageIndex = nextCandidate.next() else { return }
                    group.addTask { [session] in
                        try Task.checkCancellation()
                        if usesPreparedIndexes {
                            let index = try await session.preparedIndex(ofImageAt: imageIndex, generation: generation, isPrioritized: true) { shouldContinue in
                                analyzer.referenceIndex(ofImageAt: imageIndex, reportingProgress: shouldContinue)
                            }
                            // Naming what the index answers needs the image's
                            // function table, which a replaced analyzer dropped.
                            analyzer.keepFunctionTable(ofImageAt: imageIndex)
                            let found = findInIndex(index)
                            return (imageIndex, found, convert(found))
                        }
                        let found = await session.sharedScan(of: scanKey, inImageAt: imageIndex, generation: generation) {
                            find(imageIndex)
                        }
                        return (imageIndex, found, convert(found))
                    }
                }
                for _ in 0 ..< width { addNextScan() }
                while let scan = try await group.next() {
                    try Task.checkCancellation()
                    let (imageIndex, found, converted) = scan
                    if usesPreparedIndexes {
                        session.noteFunctionTables(ofImagesAt: [imageIndex], generation: generation)
                    } else {
                        session.record(found, for: scanKey, inImageAt: imageIndex, generation: generation)
                    }
                    let report = collector.add([(imageIndex, converted)])
                    await reportProgress(report)
                    if collector.isFull {
                        group.cancelAll()
                        break
                    }
                    addNextScan()
                }
            }
        }
        return (collector.result, cachedImageIndices.count)
    }

    // MARK: - Subjects

    /// A subject, as the functions it names and the selectors that send to
    /// it.
    struct ResolvedSubject: Sendable {
        struct Function: Sendable {
            let function: CodeFunction
            let member: RuntimeMemberReference?

            /// The names the symbol table gives the function, which is what
            /// another image imports it by.
            var symbolNames: [String] {
                var names: [String] = []
                if case .symbol(let symbol)? = function.name { names.append(symbol) }
                names.append(contentsOf: function.foldedSymbolNames)
                return names
            }
        }

        var functions: [Function] = []
        /// The Objective-C methods among the functions: every send of their
        /// selectors is a possible call.
        var objectiveCMethods: [ObjectiveCMethodName] = []
        /// A selector asked about as such: every send of it is a call.
        var selector: String?

        var selectors: Set<String> {
            var selectors = Set(objectiveCMethods.map(\.selector))
            if let selector { selectors.insert(selector) }
            return selectors
        }

        /// What a scan keeps.
        var callerKeys: Set<CodeReferenceTable.Key> {
            var keys = Set<CodeReferenceTable.Key>()
            for function in functions {
                keys.insert(.function(function.function.location))
                // A stub whose slot could not be followed names its target
                // only by the symbol it imports.
                for symbolName in function.symbolNames {
                    keys.insert(.importedSymbol(symbolName))
                }
            }
            for selector in selectors {
                keys.insert(.selector(selector))
            }
            return keys
        }
    }

    private func resolve(_ subject: RuntimeCrossReferenceSubject, with analyzer: CrossReferenceAnalyzer) async throws -> ResolvedSubject {
        switch subject {
        case .function(let imagePath, let address):
            guard let imageIndex = Self.imageIndex(forPath: imagePath, in: analyzer) else {
                throw RuntimeCrossReferenceError.imageNotFound(path: imagePath)
            }
            guard let function = analyzer.function(containing: CodeLocation(imageIndex: imageIndex, address: address)) else {
                throw RuntimeCrossReferenceError.functionNotFound(imagePath: imagePath, address: address)
            }
            return ResolvedSubject(
                functions: [ResolvedSubject.Function(function: function, member: nil)],
                objectiveCMethods: ObjectiveCMethodName.all(of: function)
            )
        case .member(let member):
            return try await resolve(member, with: analyzer)
        case .selector(let selector):
            return ResolvedSubject(selector: selector)
        }
    }

    /// A member's functions: one for a method, one per accessor for a
    /// property or a variable, and one per overload — the member list does
    /// not tell overloads apart.
    private func resolve(_ member: RuntimeMemberReference, with analyzer: CrossReferenceAnalyzer) async throws -> ResolvedSubject {
        let notFound = RuntimeCrossReferenceError.memberNotFound(objectName: member.object.displayName, memberName: member.name)
        guard let imageIndex = Self.imageIndex(forPath: member.object.imagePath, in: analyzer) else {
            throw RuntimeCrossReferenceError.imageNotFound(path: member.object.imagePath)
        }
        let addresses = try await engine.memberAddresses(for: member.object, memberName: member.name)
            .filter { MemberAddressMatching.matches($0, member) }
        var resolved = ResolvedSubject()
        var seenLocations = Set<CodeLocation>()
        for memberAddress in addresses {
            guard let address = MemberAddressMatching.address(of: memberAddress),
                  let function = analyzer.function(containing: CodeLocation(imageIndex: imageIndex, address: address)),
                  seenLocations.insert(function.location).inserted
            else { continue }
            resolved.functions.append(ResolvedSubject.Function(function: function, member: member))
            // The member list names an Objective-C method even when the
            // symbol table does not.
            if let method = ObjectiveCMethodName(symbol: memberAddress.symbolName) {
                resolved.objectiveCMethods.append(method)
            }
        }
        guard !resolved.functions.isEmpty else { throw notFound }
        return resolved
    }

    /// The analyzer's index for an image path: an install name for a shared
    /// cache image, and for any other a path whose symbolic links resolve to
    /// the image's — or, for an image the process has loaded, any path dyld
    /// opens it by.
    static func imageIndex(forPath path: String, in analyzer: CrossReferenceAnalyzer) -> Int? {
        if let imageIndex = analyzer.imageIndex(forPath: path) { return imageIndex }
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let imageIndex = analyzer.imageIndex(forPath: resolvedPath) { return imageIndex }
        if let imageIndex = analyzer.imagePaths.firstIndex(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolvedPath }) {
            return imageIndex
        }
        // `Foundation.framework/Foundation` links to `Versions/C/Foundation`,
        // a file only the shared cache holds, so the file system cannot
        // resolve it — and an engine that loaded the framework by that path
        // names its objects' image by it. dyld resolves it against the cache.
        return loadedImagePath(openedBy: path).flatMap(analyzer.imageIndex(forPath:))
    }

    /// The name dyld lists a loaded image under, for a path that opens it;
    /// `nil` when the path opens no image the process has loaded.
    static func loadedImagePath(openedBy path: String) -> String? {
        guard let handle = dlopen(path, RTLD_NOLOAD | RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        for imageIndex in 0 ..< _dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex),
                  let imageHandle = dlopen(imageName, RTLD_NOLOAD | RTLD_LAZY)
            else { continue }
            dlclose(imageHandle)
            if imageHandle == handle {
                return String(cString: imageName)
            }
        }
        return nil
    }

    /// Whether a converted reference survives
    /// ``RuntimeCrossReferenceQueryOptions/receiverClassName``.
    static func receiverMatches(_ reference: RuntimeCrossReference, options: RuntimeCrossReferenceQueryOptions) -> Bool {
        guard let wantedClassName = options.receiverClassName,
              case .selector(_, let receiverClassName?) = reference.target
        else { return true }
        return receiverClassName == wantedClassName
    }
}

// MARK: - Callers

/// Turns what a scan kept into callers of one subject: decides each
/// reference's precision and drops the sends that cannot reach it.
private struct CallerMatcher: Sendable {
    let subject: CrossReferenceQuery.ResolvedSubject
    let subjectFunctionsByLocation: [CodeLocation: RuntimeFunctionReference]
    let options: RuntimeCrossReferenceQueryOptions

    func callerReferences(from references: [CodeReference], analyzer: CrossReferenceAnalyzer) -> [RuntimeCrossReference] {
        guard !references.isEmpty else { return [] }
        let referencingFunctions = analyzer.functions(containing: references.map(\.function))
        var builder = FunctionReferenceBuilder(analyzer: analyzer)
        var referencingReferences: [CodeLocation: RuntimeFunctionReference] = [:]
        var converted: [RuntimeCrossReference] = []
        for reference in references {
            let referencingFunction = referencingFunctions[reference.function]
            let referencingReference: RuntimeFunctionReference
            if let known = referencingReferences[reference.function] {
                referencingReference = known
            } else {
                referencingReference = referencingFunction.map { builder.reference(for: $0) } ?? builder.unnamedReference(at: reference.function)
                referencingReferences[reference.function] = referencingReference
            }
            guard let callerReference = callerReference(
                reference,
                referencingFunction: referencingReference,
                sendingMethods: ObjectiveCMethodName.all(of: referencingFunction)
            ) else { continue }
            if CrossReferenceQuery.receiverMatches(callerReference, options: options) {
                converted.append(callerReference)
            }
        }
        return converted
    }

    private func callerReference(
        _ reference: CodeReference,
        referencingFunction: RuntimeFunctionReference,
        sendingMethods: [ObjectiveCMethodName]
    ) -> RuntimeCrossReference? {
        let branchKind: RuntimeCrossReferenceKind = reference.kind == .tailCall ? .tailCall : .call
        let kind: RuntimeCrossReferenceKind
        let target: RuntimeCrossReferenceTarget
        let precision: RuntimeCrossReferencePrecision
        switch reference.target {
        case .function(let location):
            guard let subjectFunction = subjectFunctionsByLocation[location] else { return nil }
            kind = branchKind
            precision = .exact
            target = .function(subjectFunction)
        case .importedSymbol(let name):
            kind = branchKind
            precision = .exact
            target = .importedSymbol(name: name)
        case .messageSend(let selector, let receiver):
            guard let sendPrecision = matchPrecision(ofSend: selector, receiver: receiver, isSuperSend: false, sendingMethods: sendingMethods) else { return nil }
            kind = .messageSend
            precision = sendPrecision
            target = .selector(name: selector, receiverClassName: ObjectiveCSendMatching.receiverClassName(of: receiver, isSuperSend: false, from: sendingMethods))
        case .superMessageSend(let selector, _):
            guard let sendPrecision = matchPrecision(ofSend: selector, receiver: .unknown, isSuperSend: true, sendingMethods: sendingMethods) else { return nil }
            kind = .superMessageSend
            precision = sendPrecision
            target = .selector(name: selector, receiverClassName: nil)
        case .objectiveCClass, .swiftType, .swiftTypeName, .indirect, .unrecognized:
            // Never filed under a caller key.
            return nil
        }
        return RuntimeCrossReference(
            referencingFunction: referencingFunction,
            instructionAddress: reference.instructionAddress,
            kind: kind,
            target: target,
            precision: precision,
            isRuntimeHelperCall: reference.isRuntimeHelperCall
        )
    }

    /// A send of a selector asked about as such is exactly what was asked
    /// for; a send to a method is weighed against the receiver.
    private func matchPrecision(ofSend selector: String, receiver: ReceiverClassHint, isSuperSend: Bool, sendingMethods: [ObjectiveCMethodName]) -> RuntimeCrossReferencePrecision? {
        if subject.selector == selector { return .exact }
        var best: RuntimeCrossReferencePrecision?
        for method in subject.objectiveCMethods where method.selector == selector {
            switch ObjectiveCSendMatching.precision(ofSendWith: receiver, isSuperSend: isSuperSend, from: sendingMethods, to: method) {
            case .exact?:
                return .exact
            case let other?:
                best = other
            case nil:
                continue
            }
        }
        return best
    }
}

/// Gathers a scan's references as images finish, and stops at the limit.
private struct ReferenceCollector {
    let totalImageCount: Int
    let resultLimit: Int?
    private var chunks: [(imageIndex: Int, references: [RuntimeCrossReference])] = []
    private var referenceCount = 0
    private var scannedImageCount = 0
    private(set) var isFull = false

    init(totalImageCount: Int, resultLimit: Int?) {
        self.totalImageCount = totalImageCount
        self.resultLimit = resultLimit
    }

    /// Adds what some images held and returns the report for them — cut at
    /// the limit, so the reports add up to exactly the result.
    mutating func add(_ imageReferences: [(imageIndex: Int, references: [RuntimeCrossReference])]) -> RuntimeCrossReferenceQueryProgress {
        var reported: [RuntimeCrossReference] = []
        for (imageIndex, references) in imageReferences {
            scannedImageCount += 1
            var kept = references
            if let resultLimit {
                let room = max(0, resultLimit - referenceCount)
                if kept.count >= room {
                    if kept.count > room || scannedImageCount < totalImageCount { isFull = true }
                    kept = Array(kept.prefix(room))
                }
            }
            referenceCount += kept.count
            chunks.append((imageIndex, kept))
            reported.append(contentsOf: kept)
        }
        return RuntimeCrossReferenceQueryProgress(scannedImageCount: scannedImageCount, totalImageCount: totalImageCount, references: reported)
    }

    var result: RuntimeCrossReferenceQueryResult {
        let references = chunks.sorted { $0.imageIndex < $1.imageIndex }.flatMap { chunk in
            chunk.references.sorted { $0.instructionAddress < $1.instructionAddress }
        }
        return RuntimeCrossReferenceQueryResult(references: references, isComplete: !isFull && scannedImageCount == totalImageCount)
    }
}

// MARK: - Type references

/// Turns what a type references scan kept into references to the type.
private enum TypeReferenceConversion {
    static func references(from references: [CodeReference], to target: RuntimeCrossReferenceTarget, analyzer: CrossReferenceAnalyzer) -> [RuntimeCrossReference] {
        guard !references.isEmpty else { return [] }
        let referencingFunctions = analyzer.functions(containing: references.map(\.function))
        var builder = FunctionReferenceBuilder(analyzer: analyzer)
        var referencingReferences: [CodeLocation: RuntimeFunctionReference] = [:]
        return references.map { reference in
            let referencingReference: RuntimeFunctionReference
            if let known = referencingReferences[reference.function] {
                referencingReference = known
            } else {
                referencingReference = referencingFunctions[reference.function].map { builder.reference(for: $0) } ?? builder.unnamedReference(at: reference.function)
                referencingReferences[reference.function] = referencingReference
            }
            return RuntimeCrossReference(
                referencingFunction: referencingReference,
                instructionAddress: reference.instructionAddress,
                kind: .typeReference,
                target: target,
                precision: .exact,
                isRuntimeHelperCall: reference.isRuntimeHelperCall
            )
        }
    }
}

// MARK: - Members

/// Picks a member's rows out of `RuntimeEngine.memberAddresses(for:memberName:)`,
/// which matches names loosely — it serves a search box.
enum MemberAddressMatching {
    static func matches(_ memberAddress: RuntimeMemberAddress, _ member: RuntimeMemberReference) -> Bool {
        let kind = memberAddress.kind
        switch member.kind {
        case .objcMethod:
            return memberAddress.name == member.name && kind == (member.isStatic ? "class method" : "method")
        case .objcProperty:
            return memberAddress.name == member.name && kind.hasPrefix(member.isStatic ? "class property " : "property ")
        case .swiftFunction:
            return memberAddress.name == member.name && kind == (member.isStatic ? "static func" : "func")
        case .swiftInitializer:
            // The member list names every initializer `init`; the rows carry
            // the definitions' own names.
            return kind == "init" || kind == "allocator"
        case .swiftVariable:
            let (isStatic, accessor) = split(kind)
            return memberAddress.name == member.name && isStatic == member.isStatic
                && !["func", "init", "allocator"].contains(accessor) && !accessor.hasPrefix("subscript.")
        case .swiftSubscript:
            let (isStatic, accessor) = split(kind)
            return isStatic == member.isStatic && accessor.hasPrefix("subscript.")
        case .objcIvar, .swiftField, .swiftEnumCase:
            // Storage, not code.
            return false
        }
    }

    /// The unslid address a row prints as hexadecimal.
    static func address(of memberAddress: RuntimeMemberAddress) -> UInt64? {
        var digits = Substring(memberAddress.address)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        return UInt64(digits, radix: 16)
    }

    private static func split(_ kind: String) -> (isStatic: Bool, rest: Substring) {
        kind.hasPrefix("static ") ? (true, kind.dropFirst("static ".count)) : (false, Substring(kind))
    }
}

// MARK: - Logging

@Loggable(.private)
private enum CrossReferenceQueryLog {
    static func answered(_ query: String, candidateCount: Int, cachedCount: Int, referenceCount: Int, isComplete: Bool, elapsed: TimeInterval) {
        #log(.debug, "\(query, privacy: .public) query scanned \(candidateCount, privacy: .public) candidate images (\(cachedCount, privacy: .public) from earlier scans), found \(referenceCount, privacy: .public) references\(isComplete ? "" : " before stopping at the limit", privacy: .public) in \(Int(elapsed * 1000), privacy: .public) ms")
    }
}

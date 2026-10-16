import Foundation
import FoundationToolbox
import RuntimeViewerCore
import CrossReferenceAnalysis

/// Answers the cross-reference commands in the process that serves the
/// engine, against that process's images.
///
/// Callees decode one function. Callers are found by an on-demand scan: the
/// images that cannot reference the subject are filtered out first — by the
/// symbols they import and the selectors they reference — and the rest are
/// scanned concurrently, keeping only the references to the subject.
struct CrossReferenceQuery {
    let engine: RuntimeEngine
    let session: CrossReferenceSession

    init(engine: RuntimeEngine, session: CrossReferenceSession) {
        self.engine = engine
        self.session = session
    }

    // MARK: - Callees

    func callees(of subject: RuntimeCrossReferenceSubject, options: RuntimeCrossReferenceQueryOptions) async throws -> RuntimeCrossReferenceQueryResult {
        if case .selector(let selector) = subject {
            throw RuntimeCrossReferenceError.selectorHasNoCallees(selector)
        }
        let (analyzer, generation) = try session.currentAnalyzer()
        let resolvedSubject = try await resolve(subject, with: analyzer)
        var builder = FunctionReferenceBuilder(imagePaths: analyzer.imagePaths)
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
                guard let converted = calleeReference(
                    reference,
                    referencingFunction: referencingFunction,
                    sendingMethods: sendingMethods,
                    analyzer: analyzer,
                    builder: &builder
                ) else { continue }
                if !Self.receiverMatches(converted, options: options) { continue }
                references.append(converted)
            }
            session.noteFunctionTables(ofImagesAt: targetImageIndices.union([subjectFunction.function.location.imageIndex]), generation: generation)
        }

        if let resultLimit = options.resultLimit, references.count > resultLimit {
            return RuntimeCrossReferenceQueryResult(references: Array(references.prefix(max(0, resultLimit))), isComplete: false)
        }
        return RuntimeCrossReferenceQueryResult(references: references, isComplete: true)
    }

    private func calleeReference(
        _ reference: CodeReference,
        referencingFunction: RuntimeFunctionReference,
        sendingMethods: [ObjectiveCMethodName],
        analyzer: CrossReferenceAnalyzer,
        builder: inout FunctionReferenceBuilder
    ) -> RuntimeCrossReference? {
        let branchKind: RuntimeCrossReferenceKind = reference.kind == .tailCall ? .tailCall : .call
        let kind: RuntimeCrossReferenceKind
        let target: RuntimeCrossReferenceTarget
        let precision: RuntimeCrossReferencePrecision
        switch reference.target {
        case .function(let location):
            kind = branchKind
            precision = .exact
            if let function = analyzer.function(containing: location), function.location == location {
                target = .function(builder.reference(for: function))
            } else {
                target = .function(builder.unnamedReference(at: location))
            }
        case .importedSymbol(let name):
            kind = branchKind
            precision = .exact
            target = .importedSymbol(name: name)
        case .messageSend(let selector, let receiver):
            kind = .messageSend
            let receiverClassName = ObjectiveCSendMatching.receiverClassName(of: receiver, isSuperSend: false, from: sendingMethods)
            precision = receiverClassName == nil ? .matchedBySelector : .exact
            target = .selector(name: selector, receiverClassName: receiverClassName)
        case .superMessageSend(let selector):
            kind = .superMessageSend
            precision = .exact
            target = .selector(name: selector, receiverClassName: nil)
        case .typeMetadataAccessor(let symbolName):
            kind = .typeReference
            precision = .exact
            target = .type(name: CrossReferenceNaming.displayName(forSymbol: symbolName), object: nil)
        case .mangledTypeName(let mangledName):
            kind = .typeReference
            precision = .exact
            target = .type(name: CrossReferenceNaming.displayName(forSymbol: mangledName), object: nil)
        case .objectiveCClass(let name):
            kind = .typeReference
            precision = .exact
            target = .type(name: name, object: nil)
        case .indirect(let evidence):
            kind = .indirectCall
            // No candidates are listed yet: the target is one of the
            // functions the evidence could lead to.
            precision = .candidate
            target = .indirect(tableOffset: evidence.tableOffset, pointerAuthenticationConstant: evidence.pointerAuthenticationConstant)
        case .unrecognized(let address):
            kind = branchKind
            precision = .exact
            target = .unrecognizedCode(address: address)
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

    // MARK: - Callers

    func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult {
        let startTime = Date()
        let (analyzer, generation) = try session.currentAnalyzer()
        let resolvedSubject = try await resolve(subject, with: analyzer)
        // Finding the subject kept its image's function table.
        session.noteFunctionTables(ofImagesAt: resolvedSubject.functions.map(\.function.location.imageIndex), generation: generation)
        let keys = resolvedSubject.callerKeys
        let candidates = try candidateImages(for: resolvedSubject, in: scope, analyzer: analyzer)
        var builder = FunctionReferenceBuilder(imagePaths: analyzer.imagePaths)
        var subjectFunctionsByLocation: [CodeLocation: RuntimeFunctionReference] = [:]
        for subjectFunction in resolvedSubject.functions where subjectFunctionsByLocation[subjectFunction.function.location] == nil {
            subjectFunctionsByLocation[subjectFunction.function.location] = builder.reference(for: subjectFunction.function, member: subjectFunction.member)
        }
        let matcher = CallerMatcher(subject: resolvedSubject, subjectFunctionsByLocation: subjectFunctionsByLocation, options: options)

        var collector = CallerCollector(totalImageCount: candidates.count, resultLimit: options.resultLimit)

        // What earlier scans for the same subject found is reported first, in
        // one event.
        let scanned = session.scannedReferences(for: keys, generation: generation)
        let remainingCandidates = candidates.filter { scanned[$0] == nil }
        let cachedImageIndices = candidates.filter { scanned[$0] != nil }
        if !cachedImageIndices.isEmpty {
            var cachedReferences: [(imageIndex: Int, references: [RuntimeCrossReference])] = []
            for imageIndex in cachedImageIndices {
                let found = scanned[imageIndex] ?? []
                cachedReferences.append((imageIndex, matcher.callerReferences(from: found, analyzer: analyzer)))
            }
            let report = collector.add(cachedReferences)
            await reportProgress(report)
        }

        if !collector.isFull, !remainingCandidates.isEmpty {
            // One cooperative thread is left to the rest of the process: each
            // child scans synchronously, for up to a tenth of a second on the
            // largest images.
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
            try await withThrowingTaskGroup(of: (Int, [CodeReference], [RuntimeCrossReference]).self) { group in
                var nextCandidate = remainingCandidates.makeIterator()
                func addNextScan() {
                    guard let imageIndex = nextCandidate.next() else { return }
                    group.addTask {
                        try Task.checkCancellation()
                        let found = analyzer.references(to: keys, inImageAt: imageIndex)
                        return (imageIndex, found, matcher.callerReferences(from: found, analyzer: analyzer))
                    }
                }
                for _ in 0 ..< width { addNextScan() }
                while let scan = try await group.next() {
                    try Task.checkCancellation()
                    let (imageIndex, found, converted) = scan
                    session.record(found, for: keys, inImageAt: imageIndex, generation: generation)
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

        let result = collector.result
        CrossReferenceQueryLog.callersAnswered(
            candidateCount: candidates.count,
            cachedCount: cachedImageIndices.count,
            referenceCount: result.references.count,
            isComplete: result.isComplete,
            elapsed: Date().timeIntervalSince(startTime)
        )
        return result
    }

    /// The images a scope asks about that can reference the subject.
    private func candidateImages(for subject: ResolvedSubject, in scope: RuntimeCrossReferenceScope, analyzer: CrossReferenceAnalyzer) throws -> [Int] {
        switch scope {
        case .image(let path):
            guard let imageIndex = Self.imageIndex(forPath: path, in: analyzer) else {
                throw RuntimeCrossReferenceError.imageNotFound(path: path)
            }
            return [imageIndex]
        case .allImages:
            let allImages = analyzer.imagePaths.indices
            var candidates = Set<Int>()
            for subjectFunction in subject.functions {
                // A function its own image can always reach; another image
                // only through a symbol it imports.
                candidates.insert(subjectFunction.function.location.imageIndex)
                for symbolName in subjectFunction.symbolNames {
                    candidates.formUnion(analyzer.imageIndices(importing: symbolName, among: allImages))
                }
            }
            for selector in subject.selectors {
                candidates.formUnion(analyzer.imageIndices(referencingSelector: selector, among: allImages))
            }
            return candidates.sorted()
        }
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
    /// the image's.
    static func imageIndex(forPath path: String, in analyzer: CrossReferenceAnalyzer) -> Int? {
        if let imageIndex = analyzer.imageIndex(forPath: path) { return imageIndex }
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let imageIndex = analyzer.imageIndex(forPath: resolvedPath) { return imageIndex }
        return analyzer.imagePaths.firstIndex { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolvedPath }
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
        var builder = FunctionReferenceBuilder(imagePaths: analyzer.imagePaths)
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
        case .superMessageSend(let selector):
            guard let sendPrecision = matchPrecision(ofSend: selector, receiver: .unknown, isSuperSend: true, sendingMethods: sendingMethods) else { return nil }
            kind = .superMessageSend
            precision = sendPrecision
            target = .selector(name: selector, receiverClassName: nil)
        case .typeMetadataAccessor, .mangledTypeName, .objectiveCClass, .indirect, .unrecognized:
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

/// Gathers a callers query's references as images finish, and stops at the
/// limit.
private struct CallerCollector {
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
    static func callersAnswered(candidateCount: Int, cachedCount: Int, referenceCount: Int, isComplete: Bool, elapsed: TimeInterval) {
        #log(.debug, "Callers query scanned \(candidateCount, privacy: .public) candidate images (\(cachedCount, privacy: .public) from earlier scans), found \(referenceCount, privacy: .public) references\(isComplete ? "" : " before stopping at the limit", privacy: .public) in \(Int(elapsed * 1000), privacy: .public) ms")
    }
}

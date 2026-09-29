import Foundation
import FoundationToolbox
import Semantic

/// One object's contribution to the corpus: its interface, printed once with
/// everything any Generation Options could show, the regions saying which
/// options hide which parts of it, and the members its structures list, each
/// aligned with a line of that interface.
struct RuntimeInterfaceCorpusEntry: Sendable {
    let object: RuntimeObject

    /// Everything any Generation Options could show; a search reads it
    /// through `visibilityRegions` under the options it was given.
    let interface: FrozenSemanticString

    let visibilityRegions: VisibilityRegionTable

    let members: [RuntimeMemberDeclaration]

    /// Where each member's declaration line lies in `interface`, as UTF-8
    /// offsets — `nil` for a member the locator found no line for. A member
    /// is shown under some options when something of its line survives the
    /// projection.
    let memberDeclarationLineRanges: [Range<Int>?]

    init(object: RuntimeObject, interface: FrozenSemanticString, visibilityRegions: VisibilityRegionTable = .empty, members: [RuntimeMemberDeclaration]) {
        self.object = object
        self.interface = interface
        self.visibilityRegions = visibilityRegions
        self.members = members
        let lineStartOffsets = Self.lineStartOffsets(of: interface.text)
        let textByteCount = interface.text.utf8.count
        memberDeclarationLineRanges = members.map { member in
            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineStartOffsets.count else { return nil }
            let lineStart = lineStartOffsets[lineNumber - 1]
            let lineEnd = lineNumber < lineStartOffsets.count ? lineStartOffsets[lineNumber] - 1 : textByteCount
            return lineStart ..< lineEnd
        }
    }

    /// Resident bytes: the text once, the span table, the interned
    /// identifiers, the region table. The `RuntimeObject` and member list are
    /// not counted — they are small next to the text and shared with the
    /// section anyway.
    var byteCount: Int {
        interface.text.utf8.count
            + interface.spans.count * MemoryLayout<FrozenSemanticString.Span>.stride
            + interface.identifierTable.reduce(0) { $0 + $1.utf8.count }
            + visibilityRegions.regions.count * MemoryLayout<VisibilityRegionTable.Region>.stride
    }

    /// The interface as it reads under `visibility`: `interface` itself when
    /// nothing in it depends on the options.
    func projection(under visibility: RuntimeInterfaceVisibility) -> VisibilityProjection? {
        guard !visibilityRegions.isEmpty else { return nil }
        return visibilityRegions.projection(of: interface, where: visibility.isOptionEnabled)
    }

    /// The member at `memberIndex` as the projection shows it — its line
    /// number and declaration line in the projected text — or `nil` when the
    /// projection hid it. A member with no known line is kept as it is.
    func member(at memberIndex: Int, in projection: VisibilityProjection, projectedLineStartOffsets: [Int]) -> RuntimeMemberDeclaration? {
        let member = members[memberIndex]
        guard let lineRange = memberDeclarationLineRanges[memberIndex] else { return member }
        let originalBytes = interface.text.utf8
        var surviving: Int?
        var byteIndex = originalBytes.index(originalBytes.startIndex, offsetBy: lineRange.lowerBound)
        for byteOffset in lineRange {
            let byte = originalBytes[byteIndex]
            if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t"), let projectedOffset = projection.projectedUTF8Offset(ofOriginalUTF8Offset: byteOffset) {
                surviving = projectedOffset
                break
            }
            byteIndex = originalBytes.index(after: byteIndex)
        }
        guard let surviving else { return nil }
        let lineIndex = Self.lineIndex(containing: surviving, lineStartOffsets: projectedLineStartOffsets)
        let projectedText = projection.text.text.utf8
        let lineStart = projectedLineStartOffsets[lineIndex]
        let lineEnd = lineIndex + 1 < projectedLineStartOffsets.count ? projectedLineStartOffsets[lineIndex + 1] - 1 : projectedText.count
        let lineText = String(decoding: projectedText.dropFirst(lineStart).prefix(lineEnd - lineStart), as: UTF8.self)
        return member.located(at: lineIndex + 1, declarationText: lineText.trimmingCharacters(in: .whitespaces))
    }

    static func lineStartOffsets(of text: String) -> [Int] {
        var offsets = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") {
            offsets.append(offset + 1)
        }
        return offsets
    }

    private static func lineIndex(containing offset: Int, lineStartOffsets: [Int]) -> Int {
        var lowerBound = 0
        var upperBound = lineStartOffsets.count
        while upperBound - lowerBound > 1 {
            let middle = (lowerBound + upperBound) / 2
            if lineStartOffsets[middle] <= offset {
                lowerBound = middle
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }
}

/// What the store needs from the engine to build an image's corpus. The
/// engine conforms; the store never sees a section.
protocol RuntimeInterfaceCorpusBuilding: AnyObject, Sendable {
    /// Every object of the image, nested children included, in listing
    /// order.
    func corpusObjects(in imagePath: String) async throws -> [RuntimeObject]

    /// The object's corpus entry: its interface printed once, with
    /// `transformer`, marked for every combination of the Generation
    /// Options. `nil` when the object has no interface. Throws when printing
    /// fails; the store skips that object and carries on.
    func corpusEntry(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusEntry?
}

/// The engine-side home of every searchable interface.
///
/// Lives on the `RuntimeEngine` that owns the images, so the text never
/// crosses a process boundary — searches travel as requests and results.
/// The proposal `draft-find-navigator` §1 is the contract; the points that
/// matter when changing this:
///
/// - **One build at a time, `.utility` priority.** Printing a large image
///   takes minutes and must not compete with the user's own loads. Images
///   queue in request order; the same image queued twice joins the one build.
/// - **A build is a subscription.** Every `build(imagePath:…)` call is one
///   subscriber of that image's build; the build is cancelled only when the
///   last subscriber goes away. Two documents sharing the `.local` engine
///   therefore cannot cancel each other's corpus.
/// - **Cancellation leaves nothing behind; failure is remembered.** A
///   cancelled build is simply not built. A build that threw is recorded as
///   `failed` and stays so until the image is asked for again, which retries.
///   One object that fails to print does not fail the build — it is skipped
///   and counted.
/// - **One print serves every Generation Options value.** Each interface is
///   printed with everything any options could show, the optional parts
///   marked with the option they depend on; a search reads it through those
///   marks under the options it carries, so changing them rebuilds nothing.
/// - **Transformer fingerprint.** The transformer rewrites text with the
///   user's own templates, which no mark can anticipate, so an entry set
///   records the configuration it was printed with; asking for the image
///   with a different one evicts and rebuilds.
/// - **Resident budget.** When the total exceeds `residentByteLimit` the
///   least recently searched images are evicted whole, back to unbuilt,
///   never the image that just finished.
@Loggable(.private)
actor RuntimeInterfaceCorpusStore {
    typealias BuildProgressHandler = @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void

    static let defaultResidentByteLimit = 256 * 1024 * 1024

    /// How many objects are printed between two progress reports.
    static let progressReportStride = 8

    struct ImageCorpus: Sendable {
        let entries: [RuntimeInterfaceCorpusEntry]
        let summary: RuntimeInterfaceCorpusBuildSummary
        let transformer: Transformer.Configuration
        var lastSearchedAt: Date
    }

    private struct Subscriber {
        let identifier: UInt64
        let onProgress: BuildProgressHandler
        let continuation: CheckedContinuation<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>
    }

    private struct Build {
        let transformer: Transformer.Configuration
        var subscribers: [Subscriber] = []
        var task: Task<Void, Never>?
        var progress = RuntimeInterfaceCorpusBuildProgress(built: 0, total: 0)
    }

    private enum BuildOutcome {
        case built(ImageCorpus)
        case failed(any Swift.Error)
        case cancelled
    }

    /// `unowned` for the same reason as `RuntimeBackgroundIndexingManager.engine`:
    /// the engine owns this store, and a strong back-reference would keep
    /// engine, store and every corpus alive across a source switch.
    private unowned let builder: any RuntimeInterfaceCorpusBuilding

    private(set) var residentByteLimit: Int

    private var corpora: [String: ImageCorpus] = [:]

    private var builds: [String: Build] = [:]

    /// Images waiting for the single build slot, in request order.
    private var pendingImagePaths: [String] = []

    private var runningImagePath: String?

    private var failureMessages: [String: String] = [:]

    private var nextSubscriberIdentifier: UInt64 = 0

    init(builder: any RuntimeInterfaceCorpusBuilding, residentByteLimit: Int = RuntimeInterfaceCorpusStore.defaultResidentByteLimit) {
        self.builder = builder
        self.residentByteLimit = residentByteLimit
    }

    // MARK: - Reading

    var residentByteCount: Int {
        corpora.values.reduce(0) { $0 + $1.summary.byteCount }
    }

    var builtImagePaths: Set<String> {
        Set(corpora.keys)
    }

    func corpus(for imagePath: String) -> ImageCorpus? {
        corpora[imagePath]
    }

    /// `indexedImagePaths` are the images the engine has indexed; those the
    /// store holds nothing for are reported as absent, not as pending.
    func coverage(indexedImagePaths: Set<String>) -> RuntimeInterfaceCorpusCoverage {
        var states: [String: RuntimeInterfaceCorpusBuildState] = [:]
        for (imagePath, corpus) in corpora {
            states[imagePath] = .built(corpus.summary)
        }
        for (imagePath, build) in builds {
            states[imagePath] = runningImagePath == imagePath ? .building(build.progress) : .pending
        }
        for (imagePath, message) in failureMessages where states[imagePath] == nil {
            states[imagePath] = .failed(message: message)
        }
        _ = indexedImagePaths
        return RuntimeInterfaceCorpusCoverage(
            statesByImagePath: states,
            residentByteCount: residentByteCount,
            residentByteLimit: residentByteLimit
        )
    }

    // MARK: - Building

    /// Builds the image's corpus, or joins the build under way, or returns
    /// the corpus already built with the same transformer. Returns when the
    /// build finishes; cancelling the calling task withdraws this
    /// subscription, and the build itself only when no subscriber is left.
    func build(
        imagePath: String,
        transformer: Transformer.Configuration,
        onProgress: @escaping BuildProgressHandler = { _ in }
    ) async throws -> RuntimeInterfaceCorpusBuildSummary {
        if let corpus = corpora[imagePath] {
            if corpus.transformer == transformer {
                return corpus.summary
            }
            #log(.info, "Corpus for \(imagePath, privacy: .public) was printed with another transformer; rebuilding")
            evict(imagePath: imagePath)
        }
        if let build = builds[imagePath], build.transformer != transformer {
            // Whoever is waiting for the old configuration would get text that
            // no longer matches what they display; they are told, and the image
            // is rebuilt for the configuration in force now.
            cancelBuild(imagePath: imagePath)
        }
        failureMessages[imagePath] = nil

        nextSubscriberIdentifier += 1
        let identifier = nextSubscriberIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let subscriber = Subscriber(identifier: identifier, onProgress: onProgress, continuation: continuation)
                if builds[imagePath] != nil {
                    builds[imagePath]!.subscribers.append(subscriber)
                } else {
                    builds[imagePath] = Build(transformer: transformer, subscribers: [subscriber])
                    pendingImagePaths.append(imagePath)
                }
                pump()
            }
        } onCancel: {
            Task { await self.unsubscribe(imagePath: imagePath, identifier: identifier) }
        }
    }

    private func unsubscribe(imagePath: String, identifier: UInt64) {
        guard var build = builds[imagePath],
              let index = build.subscribers.firstIndex(where: { $0.identifier == identifier })
        else { return }
        let subscriber = build.subscribers.remove(at: index)
        subscriber.continuation.resume(throwing: CancellationError())
        builds[imagePath] = build
        guard build.subscribers.isEmpty else { return }
        #log(.info, "Last subscriber left the corpus build of \(imagePath, privacy: .public); cancelling it")
        cancelBuild(imagePath: imagePath)
    }

    /// Cancels the image's build whether it is queued or running, resuming
    /// every remaining subscriber with `CancellationError`.
    private func cancelBuild(imagePath: String) {
        guard let build = builds[imagePath] else { return }
        if runningImagePath == imagePath {
            // `finishBuild(.cancelled)` runs when the task observes the
            // cancellation; it resumes the subscribers and frees the slot.
            build.task?.cancel()
        } else {
            pendingImagePaths.removeAll { $0 == imagePath }
            builds[imagePath] = nil
            for subscriber in build.subscribers {
                subscriber.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func pump() {
        guard runningImagePath == nil, !pendingImagePaths.isEmpty else { return }
        let imagePath = pendingImagePaths.removeFirst()
        guard var build = builds[imagePath] else {
            pump()
            return
        }
        runningImagePath = imagePath
        let transformer = build.transformer
        build.task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(imagePath: imagePath, transformer: transformer)
        }
        builds[imagePath] = build
        #log(.info, "Building corpus for \(imagePath, privacy: .public)")
    }

    /// The build itself. Actor-isolated, but every heavy step awaits a
    /// section actor, so this actor is free between objects; the `.utility`
    /// priority comes from the detached task that calls it.
    private func run(imagePath: String, transformer: Transformer.Configuration) async {
        let start = Date()
        var entries: [RuntimeInterfaceCorpusEntry] = []
        var skippedCount = 0
        let outcome: BuildOutcome
        do {
            let objects = try await builder.corpusObjects(in: imagePath)
            let total = objects.count
            entries.reserveCapacity(total)
            await publishProgress(imagePath: imagePath, built: 0, total: total)
            for (index, object) in objects.enumerated() {
                try Task.checkCancellation()
                do {
                    if let entry = try await builder.corpusEntry(for: object, transformer: transformer) {
                        entries.append(entry)
                    } else {
                        skippedCount += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skippedCount += 1
                    #log(.debug, "Skipping \(object.displayName, privacy: .public) in the corpus of \(imagePath, privacy: .public): \(error, privacy: .public)")
                }
                let built = index + 1
                if built % Self.progressReportStride == 0 || built == total {
                    await publishProgress(imagePath: imagePath, built: built, total: total)
                }
            }
            let byteCount = entries.reduce(0) { $0 + $1.byteCount }
            let summary = RuntimeInterfaceCorpusBuildSummary(objectCount: entries.count, skippedCount: skippedCount, byteCount: byteCount)
            outcome = .built(ImageCorpus(entries: entries, summary: summary, transformer: transformer, lastSearchedAt: Date()))
            #log(.info, "Built corpus for \(imagePath, privacy: .public): \(entries.count, privacy: .public) objects, \(byteCount, privacy: .public) bytes, \(skippedCount, privacy: .public) skipped, in \(Date().timeIntervalSince(start), privacy: .public) s")
        } catch is CancellationError {
            outcome = .cancelled
            #log(.info, "Cancelled the corpus build of \(imagePath, privacy: .public)")
        } catch {
            outcome = .failed(error)
            #log(.error, "Corpus build of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
        }
        finishBuild(imagePath: imagePath, outcome: outcome)
    }

    private func publishProgress(imagePath: String, built: Int, total: Int) async {
        let progress = RuntimeInterfaceCorpusBuildProgress(built: built, total: total)
        guard builds[imagePath] != nil else { return }
        builds[imagePath]!.progress = progress
        let handlers = builds[imagePath]!.subscribers.map(\.onProgress)
        for handler in handlers {
            await handler(progress)
        }
    }

    private func finishBuild(imagePath: String, outcome: BuildOutcome) {
        let build = builds.removeValue(forKey: imagePath)
        if runningImagePath == imagePath {
            runningImagePath = nil
        }
        switch outcome {
        case .built(let corpus):
            corpora[imagePath] = corpus
            failureMessages[imagePath] = nil
            build?.subscribers.forEach { $0.continuation.resume(returning: corpus.summary) }
            enforceResidentLimit(protecting: imagePath)
        case .failed(let error):
            failureMessages[imagePath] = "\(error)"
            build?.subscribers.forEach { $0.continuation.resume(throwing: error) }
        case .cancelled:
            build?.subscribers.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
        pump()
    }

    // MARK: - Eviction

    func evict(imagePath: String) {
        corpora[imagePath] = nil
        failureMessages[imagePath] = nil
        cancelBuild(imagePath: imagePath)
    }

    func evictAll() {
        corpora.removeAll()
        failureMessages.removeAll()
        for imagePath in Array(builds.keys) {
            cancelBuild(imagePath: imagePath)
        }
    }

    func setResidentByteLimit(_ limit: Int) {
        residentByteLimit = max(0, limit)
        enforceResidentLimit(protecting: nil)
    }

    private func enforceResidentLimit(protecting protectedImagePath: String?) {
        while residentByteCount > residentByteLimit {
            let candidates = corpora.filter { $0.key != protectedImagePath }
            guard let oldest = candidates.min(by: { $0.value.lastSearchedAt < $1.value.lastSearchedAt }) else { return }
            #log(.info, "Evicting the corpus of \(oldest.key, privacy: .public) (\(oldest.value.summary.byteCount, privacy: .public) bytes) to stay under \(self.residentByteLimit, privacy: .public) bytes")
            corpora[oldest.key] = nil
        }
    }

    // MARK: - Searching

    /// Runs `query` over every built corpus, pushing matches to `onProgress`
    /// one image at a time, and returns the summary. Matches are collected up
    /// to `query.resultLimit`; the count goes on past it.
    func searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        indexedImagePaths: Set<String>,
        onProgress: @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
        let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
        var totalMatchCount = 0
        var collectedCount = 0
        var scannedObjectCount = 0
        let now = Date()
        for imagePath in corpora.keys.sorted() {
            try Task.checkCancellation()
            guard let corpus = corpora[imagePath] else { continue }
            var batch: [RuntimeInterfaceSearchMatch] = []
            for entry in corpus.entries {
                scannedObjectCount += 1
                // The text the content pane shows under the query's options,
                // so every hit is visible and its line reads as displayed.
                let interface = visibility.flatMap { entry.projection(under: $0)?.text } ?? entry.interface
                totalMatchCount += RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern) { match in
                    guard collectedCount < query.resultLimit else { return false }
                    batch.append(match)
                    collectedCount += 1
                    return true
                }
            }
            corpora[imagePath]?.lastSearchedAt = now
            if !batch.isEmpty {
                await onProgress(batch)
            }
        }
        return RuntimeInterfaceSearchSummary(
            totalMatchCount: totalMatchCount,
            scannedImageCount: corpora.count,
            scannedObjectCount: scannedObjectCount,
            isTruncated: totalMatchCount > collectedCount,
            unbuiltIndexedImagePaths: indexedImagePaths.subtracting(corpora.keys).sorted()
        )
    }

    /// The member counterpart of `searchInterfaces`: substring match on
    /// member names, optional kind filter, same collection and counting rules.
    func searchMembers(
        _ query: RuntimeMemberSearchQuery,
        indexedImagePaths: Set<String>,
        onProgress: @Sendable ([RuntimeMemberMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
        var totalMatchCount = 0
        var collectedCount = 0
        var scannedObjectCount = 0
        let now = Date()
        for imagePath in corpora.keys.sorted() {
            try Task.checkCancellation()
            guard let corpus = corpora[imagePath] else { continue }
            var batch: [RuntimeMemberMatch] = []
            for entry in corpus.entries {
                scannedObjectCount += 1
                // Projected only once a member of this entry matches: most
                // entries have none, and they cost nothing.
                var projection: (projection: VisibilityProjection, lineStartOffsets: [Int])??
                for (memberIndex, member) in entry.members.enumerated() {
                    if let kinds = query.kinds, !kinds.contains(member.kind) { continue }
                    guard let range = RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, query: query.text, isCaseSensitive: query.isCaseSensitive) else { continue }
                    var shownMember = member
                    if let visibility {
                        if projection == nil {
                            projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceCorpusEntry.lineStartOffsets(of: $0.text.text)) }
                        }
                        if let entryProjection = projection ?? nil {
                            // Hidden under the query's options: not a match.
                            guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineStartOffsets: entryProjection.lineStartOffsets) else { continue }
                            shownMember = projectedMember
                        }
                    }
                    totalMatchCount += 1
                    guard collectedCount < query.resultLimit else { continue }
                    batch.append(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
                    collectedCount += 1
                }
            }
            corpora[imagePath]?.lastSearchedAt = now
            if !batch.isEmpty {
                await onProgress(batch)
            }
        }
        return RuntimeInterfaceSearchSummary(
            totalMatchCount: totalMatchCount,
            scannedImageCount: corpora.count,
            scannedObjectCount: scannedObjectCount,
            isTruncated: totalMatchCount > collectedCount,
            unbuiltIndexedImagePaths: indexedImagePaths.subtracting(corpora.keys).sorted()
        )
    }
}

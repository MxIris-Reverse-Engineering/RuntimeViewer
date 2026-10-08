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

    /// The blocks `interface` prints for the object's nested types, as UTF-8
    /// offsets in ascending order. Each nested type is an entry of its own,
    /// so a text search skips these and reports their lines there — see
    /// `RuntimeInterfaceCorpusAssembly`.
    let nestedDefinitionRanges: [Range<Int>]

    init(
        object: RuntimeObject,
        interface: FrozenSemanticString,
        visibilityRegions: VisibilityRegionTable = .empty,
        members: [RuntimeMemberDeclaration],
        nestedDefinitionRanges: [Range<Int>] = []
    ) {
        self.object = object
        self.interface = interface
        self.visibilityRegions = visibilityRegions
        self.members = members
        self.nestedDefinitionRanges = nestedDefinitionRanges
        let lineTable = RuntimeInterfaceLineTable(interface.text)
        memberDeclarationLineRanges = members.map { member in
            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineTable.lineCount else { return nil }
            return lineTable.lineUTF8Range(at: lineNumber - 1)
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

    /// `nestedDefinitionRanges` in `projection`'s text: each block from its
    /// first to its last byte the projection kept. The projection keeps the
    /// order of what it keeps, so nothing outside a block lands inside it; a
    /// block it removed whole maps to nothing.
    func nestedDefinitionRanges(in projection: VisibilityProjection) -> [Range<Int>] {
        nestedDefinitionRanges.compactMap { range in
            guard let firstKept = range.lazy.compactMap({ projection.projectedUTF8Offset(ofOriginalUTF8Offset: $0) }).first,
                  let lastKept = range.reversed().lazy.compactMap({ projection.projectedUTF8Offset(ofOriginalUTF8Offset: $0) }).first
            else { return nil }
            return firstKept ..< lastKept + 1
        }
    }

    /// The member at `memberIndex` as the projection shows it — its line
    /// number and declaration line in the projected text — or `nil` when the
    /// projection hid it. A member with no known line is kept as it is.
    func member(at memberIndex: Int, in projection: VisibilityProjection, projectedLineTable: RuntimeInterfaceLineTable) -> RuntimeMemberDeclaration? {
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
        let lineIndex = projectedLineTable.lineIndex(containingUTF8Offset: surviving)
        let projectedLineRange = projectedLineTable.lineUTF8Range(at: lineIndex)
        let lineText = String(decoding: projection.text.text.utf8.dropFirst(projectedLineRange.lowerBound).prefix(projectedLineRange.count), as: UTF8.self)
        return member.located(at: lineIndex + 1, declarationText: lineText.trimmingCharacters(in: .whitespaces))
    }
}

/// What the store needs from the engine to build an image's corpus. The
/// engine conforms; the store never sees a section.
protocol RuntimeInterfaceCorpusBuilding: AnyObject, Sendable {
    /// Every object of the image, nested children included, each followed by
    /// its own descendants — the order of `RuntimeObject.corpusFamily`.
    func corpusObjects(in imagePath: String) async throws -> [RuntimeObject]

    /// The prints of `family`, one outcome per object, in order. The first
    /// object is the one the others are nested in, at any depth, each listed
    /// after the object it is nested in: a nested type's own definition is
    /// taken out of its parent's print, so a family is printed as a unit —
    /// see `RuntimeInterfaceCorpusNesting`. Every interface is printed once,
    /// with `transformer`, marked for every combination of the Generation
    /// Options; an object that fails to print comes back `.failed` and the
    /// store carries on. Throws only when cancelled. The store makes the
    /// image's entries out of the prints once every family is printed — see
    /// `RuntimeInterfaceCorpusAssembly`.
    func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome]
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
///   queue in request order, a prioritized one ahead of the rest; the same
///   image queued twice joins the one build. Within the image, up to
///   `printingWidth` families — an object with the objects nested in it —
///   are printed at once, and the entries keep the listing order whatever
///   order the prints finish in.
/// - **A build is a subscription.** Every `build(imagePath:…)` call is one
///   subscriber of that image's build; the build is cancelled only when the
///   last subscriber goes away. Two documents sharing the `.local` engine
///   therefore cannot cancel each other's corpus.
/// - **Cancellation leaves nothing behind; failure is remembered.** A
///   cancelled build is simply not built: its subscribers hear so at once,
///   and nothing its task finishes afterwards is kept. A print in flight
///   cannot be interrupted, so a cancelled running build holds the slot
///   until its task ends; meanwhile the images queued behind it, a new
///   request for the same image included, read as pending. A build that
///   threw is recorded as `failed` and stays so until the image is asked for
///   again, which retries. One object that fails to print does not fail the
///   build — it is skipped and counted.
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

    /// How many families of an image are printed at once: four at most, half
    /// the cores on a smaller machine.
    ///
    /// Measured on a 28-core machine (`draft-find-navigator`, decision log
    /// 2026-10-01): four prints build SwiftUI's corpus in 6.7 s against 17 s
    /// for one, at a third more processor time; fourteen take 12 s and six
    /// times the processor time of four, contending in MachOSwiftSection's
    /// symbol index. Rests on two upstream changes, MachOSwiftSection's
    /// concurrent definition printing and swift-demangling's unretained kind
    /// queries: without the first, two prints of one image race on the
    /// definitions they index; without the second, they contend on one
    /// reference count so hard that four prints are slower than one.
    static let defaultPrintingWidth = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

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

    /// A build that takes subscribers. A cancelled build leaves `builds` at
    /// once, its subscribers told; whatever its task still produces after
    /// that — progress, a whole corpus — is dropped, because `identifier`
    /// no longer names the image's build.
    private struct Build {
        /// Tells this build from a later one of the same image.
        let identifier: UInt64
        let transformer: Transformer.Configuration
        var subscribers: [Subscriber] = []
        var progress = RuntimeInterfaceCorpusBuildProgress(built: 0, total: 0)
    }

    /// The build holding the single slot. It keeps the slot after it is
    /// cancelled, until its task ends — a print in flight cannot be
    /// interrupted — while its image may already have a newer build, queued
    /// behind it.
    private struct RunningBuild {
        let buildIdentifier: UInt64
        let task: Task<Void, Never>
    }

    private enum BuildOutcome {
        case built(ImageCorpus)
        case failed(any Swift.Error)
        case cancelled
    }

    /// Not a strong reference: the engine owns this store, and a strong
    /// back-reference would keep engine, store and every corpus alive across
    /// a source switch. Not `unowned` either: the engine can go away with
    /// builds still queued, before the eviction its `stop()` schedules
    /// reaches this actor, and the next build to start then read a released
    /// object and aborted the process. A build that finds it gone ends
    /// cancelled; a build under way holds it until it ends.
    private weak var builder: (any RuntimeInterfaceCorpusBuilding)?

    private(set) var residentByteLimit: Int

    private let printingWidth: Int

    private var corpora: [String: ImageCorpus] = [:]

    private var builds: [String: Build] = [:]

    /// Images waiting for the single build slot, in request order.
    private var pendingImagePaths: [String] = []

    private var runningBuild: RunningBuild?

    private var failureMessages: [String: String] = [:]

    private var nextSubscriberIdentifier: UInt64 = 0

    private var nextBuildIdentifier: UInt64 = 0

    /// `RuntimeInterfaceCorpusAssembly.entries(from:)`, replaceable so a test
    /// can hold a build in its assembly and act on it there.
    private let assembleEntries: @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry]

    private let regularExpressionTimeLimit: TimeInterval

    init(
        builder: any RuntimeInterfaceCorpusBuilding,
        residentByteLimit: Int = RuntimeInterfaceCorpusStore.defaultResidentByteLimit,
        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth,
        regularExpressionTimeLimit: TimeInterval = RuntimeInterfaceTextMatcher.RegularExpressionBudget.defaultTimeLimit,
        assembleEntries: @escaping @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry] = { prints in RuntimeInterfaceCorpusAssembly.entries(from: prints) }
    ) {
        self.builder = builder
        self.residentByteLimit = residentByteLimit
        self.printingWidth = max(1, printingWidth)
        self.regularExpressionTimeLimit = regularExpressionTimeLimit
        self.assembleEntries = assembleEntries
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

    /// How many requests wait on the image's build — what a test checks
    /// before it acts on a subscription it has just made.
    func subscriberCount(for imagePath: String) -> Int {
        builds[imagePath]?.subscribers.count ?? 0
    }

    /// Every image the store knows about. An image it holds nothing for —
    /// never asked for, evicted, cancelled — is absent from the map, not
    /// reported as pending.
    func coverage() -> RuntimeInterfaceCorpusCoverage {
        var states: [String: RuntimeInterfaceCorpusBuildState] = [:]
        for (imagePath, corpus) in corpora {
            states[imagePath] = .built(corpus.summary)
        }
        for (imagePath, build) in builds {
            states[imagePath] = runningBuild?.buildIdentifier == build.identifier ? .building(build.progress) : .pending
        }
        for (imagePath, message) in failureMessages where states[imagePath] == nil {
            states[imagePath] = .failed(message: message)
        }
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
    /// `isPrioritized` queues the image ahead of every other waiting one, as
    /// `prioritize(imagePath:)` does.
    func build(
        imagePath: String,
        transformer: Transformer.Configuration,
        isPrioritized: Bool = false,
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
                // `builds` never holds a cancelled build, so a subscriber that
                // joins here cannot inherit a cancellation meant for others.
                if builds[imagePath] != nil {
                    builds[imagePath]!.subscribers.append(subscriber)
                } else {
                    nextBuildIdentifier += 1
                    builds[imagePath] = Build(identifier: nextBuildIdentifier, transformer: transformer, subscribers: [subscriber])
                    pendingImagePaths.append(imagePath)
                }
                if isPrioritized {
                    prioritize(imagePath: imagePath)
                }
                pump()
            }
        } onCancel: {
            Task { await self.unsubscribe(imagePath: imagePath, identifier: identifier) }
        }
    }

    /// Moves a queued image to the front of the queue, so it is the next one
    /// built. Adds no subscription, and does not interrupt the image being
    /// built: a large image under way still finishes first. An image that is
    /// not waiting is left alone.
    func prioritize(imagePath: String) {
        guard let index = pendingImagePaths.firstIndex(of: imagePath), index > 0 else { return }
        pendingImagePaths.remove(at: index)
        pendingImagePaths.insert(imagePath, at: 0)
        #log(.debug, "Moved the corpus build of \(imagePath, privacy: .public) to the front of the queue")
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
    /// every remaining subscriber with `CancellationError` at once. A running
    /// build keeps the slot until its task ends, but it leaves `builds` now:
    /// a request that comes after it starts a build of its own, queued behind
    /// it, instead of joining one that is already lost.
    private func cancelBuild(imagePath: String) {
        guard let build = builds.removeValue(forKey: imagePath) else { return }
        if let runningBuild, runningBuild.buildIdentifier == build.identifier {
            // `finishBuild` frees the slot when the task ends, and drops what
            // it produced: this build is no longer in `builds`.
            runningBuild.task.cancel()
        } else {
            pendingImagePaths.removeAll { $0 == imagePath }
        }
        for subscriber in build.subscribers {
            subscriber.continuation.resume(throwing: CancellationError())
        }
    }

    private func pump() {
        guard runningBuild == nil, !pendingImagePaths.isEmpty else { return }
        let imagePath = pendingImagePaths.removeFirst()
        guard let build = builds[imagePath] else {
            pump()
            return
        }
        let buildIdentifier = build.identifier
        let transformer = build.transformer
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(imagePath: imagePath, buildIdentifier: buildIdentifier, transformer: transformer)
        }
        runningBuild = RunningBuild(buildIdentifier: buildIdentifier, task: task)
        #log(.info, "Building corpus for \(imagePath, privacy: .public)")
    }

    /// The build itself. Actor-isolated, but every heavy step happens in a
    /// child task off this actor, which stays free between completions; the
    /// `.utility` priority comes from the detached task that calls it.
    /// Families print `printingWidth` at a time and their prints land in the
    /// slots of the objects they belong to, so the entries keep the listing
    /// order. `buildIdentifier` goes with everything it reports: once the
    /// build is cancelled the image's build is another one, or none.
    private func run(imagePath: String, buildIdentifier: UInt64, transformer: Transformer.Configuration) async {
        let start = Date()
        var skippedCount = 0
        let outcome: BuildOutcome
        do {
            guard let builder else { throw CancellationError() }
            let objects = try await builder.corpusObjects(in: imagePath)
            let total = objects.count
            await publishProgress(imagePath: imagePath, buildIdentifier: buildIdentifier, built: 0, total: total)
            var printsByObjectIndex = [RuntimeInterfaceCorpusPrint?](repeating: nil, count: total)
            let families = Self.families(in: objects)
            func printOperation(forFamilyAt familyIndex: Int) -> @Sendable () async throws -> (Range<Int>, [RuntimeInterfaceCorpusPrintOutcome]) {
                let familyRange = families[familyIndex]
                let family = Array(objects[familyRange])
                return {
                    try Task.checkCancellation()
                    return (familyRange, try await builder.corpusPrints(of: family, transformer: transformer))
                }
            }
            try await withThrowingTaskGroup(of: (Range<Int>, [RuntimeInterfaceCorpusPrintOutcome]).self) { group in
                var nextFamilyIndex = 0
                while nextFamilyIndex < min(printingWidth, families.count) {
                    group.addTask(operation: printOperation(forFamilyAt: nextFamilyIndex))
                    nextFamilyIndex += 1
                }
                var built = 0
                while let (familyRange, printOutcomes) = try await group.next() {
                    for (offset, objectIndex) in familyRange.enumerated() {
                        let printOutcome = offset < printOutcomes.count ? printOutcomes[offset] : .failed("its family's print had no outcome for it")
                        switch printOutcome {
                        case .printed(let objectPrint):
                            printsByObjectIndex[objectIndex] = objectPrint
                        case .empty:
                            skippedCount += 1
                        case .failed(let message):
                            skippedCount += 1
                            #log(.debug, "Skipping \(objects[objectIndex].displayName, privacy: .public) in the corpus of \(imagePath, privacy: .public): \(message, privacy: .public)")
                        }
                    }
                    let previouslyBuilt = built
                    built += familyRange.count
                    if built / Self.progressReportStride > previouslyBuilt / Self.progressReportStride || built == total {
                        await publishProgress(imagePath: imagePath, buildIdentifier: buildIdentifier, built: built, total: total)
                    }
                    if nextFamilyIndex < families.count {
                        group.addTask(operation: printOperation(forFamilyAt: nextFamilyIndex))
                        nextFamilyIndex += 1
                    }
                }
            }
            // Saves an assembly nobody will take. A cancellation that comes
            // during the assembly is caught by `finishBuild`.
            try Task.checkCancellation()
            let entries = await assemble(printsByObjectIndex.compactMap { $0 })
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
        finishBuild(imagePath: imagePath, buildIdentifier: buildIdentifier, outcome: outcome)
    }

    /// The objects in print units, each a range of the listing: an object
    /// with the objects nested in it where the listing shows them that way —
    /// the object followed by its descendants, as `RuntimeObject.corpusFamily`
    /// orders them — and every other object on its own.
    static func families(in objects: [RuntimeObject]) -> [Range<Int>] {
        var families: [Range<Int>] = []
        var index = 0
        while index < objects.count {
            let family = objects[index].corpusFamily
            let end = index + family.count
            if family.count > 1, end <= objects.count, zip(objects[index ..< end], family).allSatisfy({ $0.key == $1.key }) {
                families.append(index ..< end)
                index = end
            } else {
                families.append(index ..< index + 1)
                index += 1
            }
        }
        return families
    }

    /// The image's entries out of its prints. `nonisolated` so the pass —
    /// a walk over every interface of the image — runs off this actor, which
    /// stays free to answer searches and coverage meanwhile.
    private nonisolated func assemble(_ prints: [RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry] {
        await assembleEntries(prints)
    }

    /// Reaches only the subscribers of build `buildIdentifier`: a cancelled
    /// build's task may still report while a newer build of its image waits
    /// for the slot.
    private func publishProgress(imagePath: String, buildIdentifier: UInt64, built: Int, total: Int) async {
        guard var build = builds[imagePath], build.identifier == buildIdentifier else { return }
        let progress = RuntimeInterfaceCorpusBuildProgress(built: built, total: total)
        build.progress = progress
        builds[imagePath] = build
        let handlers = build.subscribers.map(\.onProgress)
        for handler in handlers {
            await handler(progress)
        }
    }

    /// Frees the slot, then settles build `buildIdentifier` — unless it was
    /// cancelled while it ran, in which case its subscribers were told then
    /// and what it produced, even a whole corpus, is stale. A subscriber's
    /// continuation is resumed in one place only: whoever takes its build out
    /// of `builds`.
    private func finishBuild(imagePath: String, buildIdentifier: UInt64, outcome: BuildOutcome) {
        if runningBuild?.buildIdentifier == buildIdentifier {
            runningBuild = nil
        }
        defer { pump() }
        guard let build = builds[imagePath], build.identifier == buildIdentifier else {
            #log(.info, "Dropping what the cancelled corpus build of \(imagePath, privacy: .public) produced")
            return
        }
        builds[imagePath] = nil
        switch outcome {
        case .built(let corpus):
            corpora[imagePath] = corpus
            failureMessages[imagePath] = nil
            build.subscribers.forEach { $0.continuation.resume(returning: corpus.summary) }
            enforceResidentLimit(protecting: imagePath)
        case .failed(let error):
            failureMessages[imagePath] = "\(error)"
            build.subscribers.forEach { $0.continuation.resume(throwing: error) }
        case .cancelled:
            // Still the image's build yet cancelled: the builder went away.
            build.subscribers.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
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

    /// One corpus as a search reads it, taken on this actor so the scan can
    /// run off it. The entries are values: a corpus evicted while the scan
    /// runs stays readable — and resident, over the budget — until the scan
    /// is done with it.
    private struct SearchedCorpus: Sendable {
        let imagePath: String
        let entries: [RuntimeInterfaceCorpusEntry]
    }

    /// What the scan of one search came to.
    private struct SearchScan: Sendable {
        var totalMatchCount = 0
        var collectedCount = 0
        var scannedObjectCount = 0
        var scannedImagePaths: [String] = []
        var stopReason: RuntimeInterfaceSearchStopReason?
    }

    /// Runs `query` over every built corpus, pushing matches to `onProgress`
    /// one image at a time, and returns the summary. Matches are collected up
    /// to `query.resultLimit`; the count goes on past it. The scan runs off
    /// this actor, so whatever the pattern costs, the store keeps answering;
    /// a regular expression that spends the search's budget stops it, with
    /// what was delivered standing and the summary saying why.
    func searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        indexedImagePaths: Set<String>,
        onProgress: @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
        let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
        let scan = try await Self.scan(
            corporaToSearch(within: query.imagePaths),
            resultLimit: query.resultLimit,
            regularExpressionTimeLimit: regularExpressionTimeLimit,
            onProgress: onProgress
        ) { entry, budget, isCollecting, collect in
            // The text the content pane shows under the query's options, so
            // every hit is visible and its line reads as displayed. Its
            // nested types' blocks are skipped: they are entries of their
            // own, which report those hits.
            let interface: FrozenSemanticString
            let nestedDefinitionRanges: [Range<Int>]
            if let projection = visibility.flatMap({ entry.projection(under: $0) }) {
                interface = projection.text
                nestedDefinitionRanges = entry.nestedDefinitionRanges.isEmpty ? [] : entry.nestedDefinitionRanges(in: projection)
            } else {
                interface = entry.interface
                nestedDefinitionRanges = entry.nestedDefinitionRanges
            }
            return try RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, budget: &budget, excludingUTF8Ranges: nestedDefinitionRanges, isCollecting: isCollecting, collect: collect)
        }
        return summary(of: scan, indexedImagePaths: indexedImagePaths, within: query.imagePaths)
    }

    /// The member counterpart of `searchInterfaces`: member names matched
    /// with the text search's match styles, optional kind filter, same
    /// collection, counting and stopping rules. An empty query matches no
    /// member.
    func searchMembers(
        _ query: RuntimeMemberSearchQuery,
        indexedImagePaths: Set<String>,
        onProgress: @Sendable ([RuntimeMemberMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        let pattern = query.text.isEmpty ? nil : try RuntimeInterfaceTextMatcher.Pattern(text: query.text, matchMode: query.matchMode, isCaseSensitive: query.isCaseSensitive)
        let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
        let kinds = query.kinds
        let scan = try await Self.scan(
            corporaToSearch(within: query.imagePaths),
            resultLimit: query.resultLimit,
            regularExpressionTimeLimit: regularExpressionTimeLimit,
            onProgress: onProgress
        ) { entry, budget, isCollectingAtStart, collect in
            guard let pattern else { return 0 }
            var matchCount = 0
            var isCollecting = isCollectingAtStart
            // Projected only once a member of this entry matches: most
            // entries have none, and they cost nothing.
            var projection: (projection: VisibilityProjection, lineTable: RuntimeInterfaceLineTable)??
            for (memberIndex, member) in entry.members.enumerated() {
                if let kinds, !kinds.contains(member.kind) { continue }
                guard let range = try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern, budget: &budget) else { continue }
                var shownMember = member
                if let visibility {
                    if projection == nil {
                        projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceLineTable($0.text.text)) }
                    }
                    if let entryProjection = projection ?? nil {
                        // Hidden under the query's options: not a match.
                        guard let projectedMember = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineTable: entryProjection.lineTable) else { continue }
                        shownMember = projectedMember
                    }
                }
                matchCount += 1
                if isCollecting {
                    isCollecting = collect(RuntimeMemberMatch(object: entry.object, member: shownMember, matchRangeInName: range))
                }
            }
            return matchCount
        }
        return summary(of: scan, indexedImagePaths: indexedImagePaths, within: query.imagePaths)
    }

    /// The built corpora a search reads, in path order — all of them, or
    /// those of `scope` when the query names some — marked searched now.
    private func corporaToSearch(within scope: Set<String>?) -> [SearchedCorpus] {
        let now = Date()
        var imagePaths = corpora.keys.sorted()
        if let scope {
            imagePaths = imagePaths.filter(scope.contains)
        }
        return imagePaths.compactMap { imagePath in
            guard let corpus = corpora[imagePath] else { return nil }
            corpora[imagePath]?.lastSearchedAt = now
            return SearchedCorpus(imagePath: imagePath, entries: corpus.entries)
        }
    }

    /// Reads `corpora` entry by entry, off this actor: the text and member
    /// searches differ only in `matchEntry`, which hands each match of an
    /// entry to its last argument — `false` back means the result limit is
    /// reached and nothing more is taken — and returns how many matches the
    /// entry has. Its third argument says whether anything is still taken
    /// when the entry starts; past the limit an entry is only counted, which
    /// needs much less work. One regular expression budget serves the whole
    /// search.
    ///
    /// Checks for cancellation before every entry and before an image's
    /// batch goes out, so a cancelled search delivers nothing more; the
    /// regular expression engine looks at the task itself in between. Yields
    /// after every image. A regular expression that spends the budget ends
    /// the scan where it is: the matches of the image under way still go
    /// out, and `stopReason` says why nothing follows.
    @concurrent
    private static func scan<Match: Sendable>(
        _ corpora: [SearchedCorpus],
        resultLimit: Int,
        regularExpressionTimeLimit: TimeInterval,
        onProgress: @Sendable ([Match]) async -> Void,
        matchEntry: @Sendable (_ entry: RuntimeInterfaceCorpusEntry, _ budget: inout RuntimeInterfaceTextMatcher.RegularExpressionBudget, _ isCollecting: Bool, _ collect: (Match) -> Bool) throws -> Int
    ) async throws -> SearchScan {
        var scan = SearchScan()
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: regularExpressionTimeLimit)
        for corpus in corpora {
            try Task.checkCancellation()
            scan.scannedImagePaths.append(corpus.imagePath)
            var batch: [Match] = []
            var collectedCount = scan.collectedCount
            do {
                for entry in corpus.entries {
                    try Task.checkCancellation()
                    scan.scannedObjectCount += 1
                    scan.totalMatchCount += try matchEntry(entry, &budget, collectedCount < resultLimit) { match in
                        guard collectedCount < resultLimit else { return false }
                        batch.append(match)
                        collectedCount += 1
                        return collectedCount < resultLimit
                    }
                }
            } catch RuntimeInterfaceTextMatcher.PatternError.regularExpressionTooExpensive {
                scan.stopReason = .regularExpressionTooExpensive
            }
            scan.collectedCount = collectedCount
            try Task.checkCancellation()
            if !batch.isEmpty {
                await onProgress(batch)
            }
            if scan.stopReason != nil {
                break
            }
            await Task.yield()
        }
        return scan
    }

    private func summary(of scan: SearchScan, indexedImagePaths: Set<String>, within scope: Set<String>?) -> RuntimeInterfaceSearchSummary {
        if scan.stopReason != nil {
            #log(.info, "A search stopped after \(scan.scannedObjectCount, privacy: .public) objects: its regular expression spent the time budget")
        }
        return RuntimeInterfaceSearchSummary(
            totalMatchCount: scan.totalMatchCount,
            scannedImagePaths: scan.scannedImagePaths,
            scannedObjectCount: scan.scannedObjectCount,
            isTruncated: scan.totalMatchCount > scan.collectedCount,
            unbuiltIndexedImagePaths: unbuiltImagePaths(among: indexedImagePaths, within: scope),
            stopReason: scan.stopReason
        )
    }

    /// The indexed images a search could not read for want of a corpus, of
    /// those it was asked to cover: all of them, or those of `scope`.
    private func unbuiltImagePaths(among indexedImagePaths: Set<String>, within scope: Set<String>?) -> [String] {
        let coveredImagePaths = scope.map(indexedImagePaths.intersection) ?? indexedImagePaths
        return coveredImagePaths.subtracting(corpora.keys).sorted()
    }
}

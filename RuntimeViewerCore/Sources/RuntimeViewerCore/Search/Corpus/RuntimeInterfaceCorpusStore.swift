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

    /// Its conditions are the copies the image's corpus stores once for all
    /// its entries — see `RuntimeInterfaceVisibilityConditionPool`.
    private(set) var visibilityRegions: VisibilityRegionTable

    /// The members its structures list, located, but without their
    /// declaration lines: each `declarationText` is the member's name,
    /// sharing its storage, and `displayedMember(at:)` reads the line back
    /// out of `interface` for a member that is shown. A copy of every line
    /// costs about as much as the text itself for a type of mostly members.
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
        self.members = members.map { member in
            RuntimeMemberDeclaration(name: member.name, kind: member.kind, isStatic: member.isStatic, declarationText: member.name, lineNumber: member.lineNumber)
        }
        self.nestedDefinitionRanges = nestedDefinitionRanges
        let lineTable = RuntimeInterfaceLineTable(interface.text)
        memberDeclarationLineRanges = members.map { member in
            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineTable.lineCount else { return nil }
            return lineTable.lineUTF8Range(at: lineNumber - 1)
        }
    }

    /// Resident bytes, estimated from what the entry allocates — its
    /// interface's text, span table and identifiers, its region table, its
    /// members with their names and line ranges, its nested blocks, and what
    /// its object holds — each allocation with its header and malloc's
    /// rounding (`allocatedByteCount`). Counted by element alone, as it used
    /// to be, the estimate fell a tenth short of what evicting Foundation's
    /// corpus frees — a fifth before the corpus stored its visibility
    /// conditions once.
    ///
    /// Not the entry itself, which the corpus's array of entries holds, nor
    /// its visibility conditions, which the corpus stores once for all its
    /// entries; `ImageCorpus.init(sharingVisibilityConditionsOf:…)` counts
    /// both. A member's `declarationText` shares its name's buffer.
    var byteCount: Int {
        interface.text.allocatedByteCount
            + interface.spans.allocatedByteCount
            + interface.identifierTable.reduce(interface.identifierTable.allocatedByteCount) { total, identifier in total + identifier.allocatedByteCount }
            + visibilityRegions.regions.allocatedByteCount
            + members.reduce(members.allocatedByteCount) { total, member in total + member.name.allocatedByteCount }
            + memberDeclarationLineRanges.allocatedByteCount
            + nestedDefinitionRanges.allocatedByteCount
            + object.name.allocatedByteCount
            + object.displayName.allocatedByteCount
            + object.children.allocatedByteCount
            + object.privateDeclarations.allocatedByteCount
    }

    /// Takes `visibilityRegions` back with its conditions swapped for the
    /// copies `pool` stores, which the image's other entries share.
    mutating func shareVisibilityConditions(in pool: inout RuntimeInterfaceVisibilityConditionPool) {
        visibilityRegions = pool.sharedTable(for: visibilityRegions)
    }

    /// The interface as it reads under `visibility`: `interface` itself when
    /// nothing in it depends on the options.
    func projection(under visibility: RuntimeInterfaceVisibility) -> VisibilityProjection? {
        guard !visibilityRegions.isEmpty else { return nil }
        RuntimeInterfaceSearchWorkLog.record(.projection)
        return visibilityRegions.projection(of: interface, where: visibility.isOptionEnabled)
    }

    /// Whether `pattern` can hit the interface as `visibility` shows it,
    /// decided without building that projection, which copies the entry
    /// several times over. Never no for an entry the projection gives a hit
    /// in, so a search can skip the entry on a no; see
    /// `RuntimeInterfaceTextMatcher.literalPattern(_:mayHitTextOf:hidingUTF8Ranges:)`.
    /// Always yes for a regular expression.
    func mayHaveHits(of pattern: RuntimeInterfaceTextMatcher.Pattern, under visibility: RuntimeInterfaceVisibility) -> Bool {
        guard pattern.regex == nil else { return true }
        let hiddenRanges = visibilityRegions.hiddenUTF8Ranges(inTextOfUTF8Count: interface.text.utf8.count, where: visibility.isOptionEnabled)
        return RuntimeInterfaceTextMatcher.literalPattern(pattern, mayHitTextOf: interface.text, hidingUTF8Ranges: hiddenRanges)
    }

    /// The member at `memberIndex` as the full interface shows it, its
    /// declaration line read back out of `interface` and trimmed of its
    /// indentation, as the locator wrote it. A member with no known line
    /// keeps its name as its declaration.
    func displayedMember(at memberIndex: Int) -> RuntimeMemberDeclaration {
        let member = members[memberIndex]
        guard let lineNumber = member.lineNumber, let lineRange = memberDeclarationLineRanges[memberIndex] else { return member }
        let lineText = String(decoding: interface.text.utf8.dropFirst(lineRange.lowerBound).prefix(lineRange.count), as: UTF8.self)
        return member.located(at: lineNumber, declarationText: lineText.trimmingCharacters(in: .whitespaces))
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
/// The proposal `0029-find-navigator` §1 is the contract; the points that
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
/// - **Resident budget** (proposal `on-demand-corpora-and-cross-references`).
///   Only `residentByteLimit` of corpora stay in memory. A corpus derived
///   data holds is built whether or not it is in memory: a search reads the
///   ones that are not back from disk, one image at a time, and keeps one if
///   it fits once the corpora searched before it are evicted, least recently
///   searched first. Builds and restores only fill the room left, in the
///   order they finish, and evict nothing. A corpus derived data cannot hold
///   — an image outside the shared cache, a print with this process's
///   addresses — is kept whatever it takes, the stored ones evicted first;
///   one evicted all the same goes back to unbuilt.
/// - **Derived data first, then the printer** (proposal `derived-data`).
///   With a derived data store, a build begins by reading the summary stored
///   for its image and transformer, off this actor, and the corpus itself
///   only when it fits in the room left; only a build that reads nothing
///   queues for the printer. A printed corpus goes into the store at once —
///   it is searchable from then on — and is written as derived data before
///   its build settles, so a finished build is a written one; it stays in
///   memory only if it fits. `restore(imagePaths:transformer:)` reads
///   without ever printing, for images that are not indexed yet. A read is
///   part of its build: whatever cancels, evicts or replaces the build drops
///   what the read brings back.
@Loggable(.private)
@Signpostable(.private)
actor RuntimeInterfaceCorpusStore {
    typealias BuildProgressHandler = @Sendable (RuntimeInterfaceCorpusBuildProgress) async -> Void

    /// What stays in memory by default; the rest is read back from derived
    /// data when a search needs it.
    static let defaultResidentByteLimit = 64 * 1024 * 1024

    /// How many objects are printed between two progress reports.
    static let progressReportStride = 8

    /// How many families of an image are printed at once: four at most, half
    /// the cores on a smaller machine.
    ///
    /// Measured on a 28-core machine (`0029-find-navigator`, decision log
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

    /// What derived data holds for an image: the configuration its corpus
    /// was printed with, and what the corpus holds.
    struct StoredCorpus: Sendable {
        let transformer: Transformer.Configuration
        let summary: RuntimeInterfaceCorpusBuildSummary
    }

    /// What a build's read of derived data brought back.
    private enum StoredRead {
        /// The corpus itself, read whole: it fitted in the room left.
        case corpus(ImageCorpus)
        /// Only what the corpus holds: it would not have fitted.
        case summary(RuntimeInterfaceCorpusBuildSummary)
    }

    private struct Subscriber {
        let identifier: UInt64
        let onProgress: BuildProgressHandler
        let continuation: CheckedContinuation<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>
    }

    /// A request of `restore(imagePaths:transformer:)` waiting on a build's
    /// read: told what the read found, and nothing about any print.
    private struct RestoreSubscriber {
        let identifier: UInt64
        let continuation: CheckedContinuation<RuntimeInterfaceCorpusRestoredImage?, Never>
    }

    /// A build that takes subscribers. A cancelled build leaves `builds` at
    /// once, its subscribers told; whatever its task still produces after
    /// that — progress, a read corpus, a printed one — is dropped, because
    /// `identifier` no longer names the image's build.
    private struct Build {
        enum Phase {
            /// Reading the corpus stored as derived data; not in the queue.
            case reading
            /// In the queue, or printing in the slot.
            case printing
        }

        /// Tells this build from a later one of the same image.
        let identifier: UInt64
        let transformer: Transformer.Configuration
        var phase: Phase
        var subscribers: [Subscriber] = []
        /// Only while `.reading`: every one is told when the read ends.
        var restoreSubscribers: [RestoreSubscriber] = []
        var progress = RuntimeInterfaceCorpusBuildProgress(built: 0, total: 0)
        /// Where a read that finds nothing puts the build in the queue: the
        /// end, the front for a prioritized one, or back where it was for a
        /// build a restore took out of the queue to read.
        var queueIndexAfterReading: Int?
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
        /// `isStored`: written as derived data, so a search can read it back.
        case built(ImageCorpus, isStored: Bool)
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

    /// The corpora in memory.
    private var corpora: [String: ImageCorpus] = [:]

    /// The images whose corpus derived data holds — read from it, or printed
    /// and written — each under the configuration it was printed with. They
    /// are built whether or not their corpus is in `corpora`: a search reads
    /// back the ones that are not. An entry goes when the image is evicted —
    /// `evict(imagePath:)`, `evictAll()`, a build under another
    /// configuration — or when reading it back fails.
    private var storedCorpora: [String: StoredCorpus] = [:]

    /// The built images whose corpus came from derived data rather than
    /// from the printer, and what reading it took. An entry goes when the
    /// image stops being built, or is printed again.
    private var restoredImages: [String: RuntimeInterfaceCorpusRestoredImage] = [:]

    /// Where corpora are read from before they are printed, and written to
    /// once they are; `nil` keeps everything in memory.
    private var derivedData: RuntimeDerivedDataStore?

    private var builds: [String: Build] = [:]

    /// Images waiting for the single build slot, in the order they joined the
    /// queue. A build that reads derived data first joins when its read finds
    /// nothing (`finishRead`), so builds asked for together are printed in
    /// the order their reads end rather than in the order they were asked for.
    private var pendingImagePaths: [String] = []

    private var runningBuild: RunningBuild?

    private var failureMessages: [String: String] = [:]

    private var nextSubscriberIdentifier: UInt64 = 0

    private var nextBuildIdentifier: UInt64 = 0

    /// `RuntimeInterfaceCorpusAssembly.entries(from:)`, replaceable so a test
    /// can hold a build in its assembly and act on it there.
    private let assembleEntries: @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry]

    /// Reads an image's stored corpus — `readStoredCorpus(from:imagePath:transformer:)`
    /// — replaceable so a test can hold a build in its read and act on it
    /// there.
    private let readStoredCorpus: @Sendable (RuntimeDerivedDataStore, String, Transformer.Configuration) async -> ImageCorpus?

    /// Reads the summary of an image's stored corpus —
    /// `readStoredSummary(from:imagePath:transformer:)` — the first step of
    /// every read; replaceable for the same reason.
    private let readStoredSummary: @Sendable (RuntimeDerivedDataStore, String, Transformer.Configuration) async -> RuntimeInterfaceCorpusBuildSummary?

    private let regularExpressionTimeLimit: TimeInterval

    init(
        builder: any RuntimeInterfaceCorpusBuilding,
        derivedData: RuntimeDerivedDataStore? = nil,
        residentByteLimit: Int = RuntimeInterfaceCorpusStore.defaultResidentByteLimit,
        printingWidth: Int = RuntimeInterfaceCorpusStore.defaultPrintingWidth,
        regularExpressionTimeLimit: TimeInterval = RuntimeInterfaceTextMatcher.RegularExpressionBudget.defaultTimeLimit,
        assembleEntries: @escaping @Sendable ([RuntimeInterfaceCorpusPrint]) async -> [RuntimeInterfaceCorpusEntry] = { prints in RuntimeInterfaceCorpusAssembly.entries(from: prints) },
        readStoredCorpus: @escaping @Sendable (RuntimeDerivedDataStore, String, Transformer.Configuration) async -> ImageCorpus? = { derivedData, imagePath, transformer in
            await RuntimeInterfaceCorpusStore.readStoredCorpus(from: derivedData, imagePath: imagePath, transformer: transformer)
        },
        readStoredSummary: @escaping @Sendable (RuntimeDerivedDataStore, String, Transformer.Configuration) async -> RuntimeInterfaceCorpusBuildSummary? = { derivedData, imagePath, transformer in
            await RuntimeInterfaceCorpusStore.readStoredSummary(from: derivedData, imagePath: imagePath, transformer: transformer)
        }
    ) {
        self.builder = builder
        self.derivedData = derivedData
        self.residentByteLimit = residentByteLimit
        self.printingWidth = max(1, printingWidth)
        self.regularExpressionTimeLimit = regularExpressionTimeLimit
        self.assembleEntries = assembleEntries
        self.readStoredCorpus = readStoredCorpus
        self.readStoredSummary = readStoredSummary
    }

    /// Reads and writes `store` from now on — how a test gives an engine
    /// derived data of its own (`RuntimeEngine.useDerivedDataStore(_:)`).
    func useDerivedData(_ store: RuntimeDerivedDataStore?) {
        derivedData = store
    }

    // MARK: - Reading

    var residentByteCount: Int {
        corpora.values.reduce(0) { $0 + $1.summary.byteCount }
    }

    /// The images whose corpus is in memory.
    var residentImagePaths: Set<String> {
        Set(corpora.keys)
    }

    /// The images whose corpus derived data holds, in memory or not.
    var storedImagePaths: Set<String> {
        Set(storedCorpora.keys)
    }

    /// The image's corpus, if it is in memory.
    func corpus(for imagePath: String) -> ImageCorpus? {
        corpora[imagePath]
    }

    /// Searchable: its corpus in memory, or held by derived data.
    private func isBuilt(_ imagePath: String) -> Bool {
        corpora[imagePath] != nil || storedCorpora[imagePath] != nil
    }

    /// What the budget has left.
    private var roomLeft: Int {
        max(0, residentByteLimit - residentByteCount)
    }

    /// How many requests wait on the image's build — what a test checks
    /// before it acts on a subscription it has just made.
    func subscriberCount(for imagePath: String) -> Int {
        builds[imagePath]?.subscribers.count ?? 0
    }

    /// Whether the image's build waits in the queue for the printer — past
    /// its read, if it had one. What a test checks before it acts on a
    /// queued build.
    func isQueued(imagePath: String) -> Bool {
        pendingImagePaths.contains(imagePath)
    }

    /// Every image the store knows about. An image it holds nothing for —
    /// never asked for, evicted, cancelled — is absent from the map, not
    /// reported as pending. A stored corpus out of memory is built.
    func coverage() -> RuntimeInterfaceCorpusCoverage {
        var states: [String: RuntimeInterfaceCorpusBuildState] = [:]
        for (imagePath, storedCorpus) in storedCorpora {
            states[imagePath] = .built(storedCorpus.summary)
        }
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
            residentByteLimit: residentByteLimit,
            restoredImagesByImagePath: restoredImages.filter { isBuilt($0.key) }
        )
    }

    /// What reading the image's corpus from derived data took, when its
    /// corpus in the store came from there.
    func restoredImage(for imagePath: String) -> RuntimeInterfaceCorpusRestoredImage? {
        isBuilt(imagePath) ? restoredImages[imagePath] : nil
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
        } else if let storedCorpus = storedCorpora[imagePath] {
            if storedCorpus.transformer == transformer {
                return storedCorpus.summary
            }
            #log(.info, "The stored corpus of \(imagePath, privacy: .public) was printed with another transformer; rebuilding")
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
                    if canRead(imagePath: imagePath) {
                        builds[imagePath] = Build(identifier: nextBuildIdentifier, transformer: transformer, phase: .reading, subscribers: [subscriber])
                        startRead(imagePath: imagePath, buildIdentifier: nextBuildIdentifier, transformer: transformer)
                    } else {
                        builds[imagePath] = Build(identifier: nextBuildIdentifier, transformer: transformer, phase: .printing, subscribers: [subscriber])
                        pendingImagePaths.append(imagePath)
                    }
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
    /// built: a large image under way still finishes first. An image whose
    /// stored corpus is being read goes to the front if the read finds
    /// nothing. An image that is not waiting is left alone.
    func prioritize(imagePath: String) {
        if var build = builds[imagePath], case .reading = build.phase {
            build.queueIndexAfterReading = 0
            builds[imagePath] = build
            return
        }
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
        if case .reading = build.phase, !build.restoreSubscribers.isEmpty {
            // A restore still waits for the read, and only for the read.
            return
        }
        #log(.info, "Last subscriber left the corpus build of \(imagePath, privacy: .public); cancelling it")
        cancelBuild(imagePath: imagePath)
    }

    private func unsubscribeRestore(imagePath: String, identifier: UInt64) {
        guard var build = builds[imagePath],
              let index = build.restoreSubscribers.firstIndex(where: { $0.identifier == identifier })
        else { return }
        let restoreSubscriber = build.restoreSubscribers.remove(at: index)
        restoreSubscriber.continuation.resume(returning: nil)
        builds[imagePath] = build
        guard build.subscribers.isEmpty, build.restoreSubscribers.isEmpty else { return }
        cancelBuild(imagePath: imagePath)
    }

    /// Cancels the image's build whether it is reading, queued or running,
    /// resuming every remaining subscriber with `CancellationError` — and
    /// every restore waiting on its read with nothing — at once. A running
    /// build keeps the slot until its task ends, and a read goes on until it
    /// ends, but the build leaves `builds` now: a request that comes after it
    /// starts a build of its own instead of joining one that is already lost.
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
        for restoreSubscriber in build.restoreSubscribers {
            restoreSubscriber.continuation.resume(returning: nil)
        }
    }

    private func pump() {
        guard runningBuild == nil, !pendingImagePaths.isEmpty else { return }
        let imagePath = pendingImagePaths.removeFirst()
        guard let build = builds[imagePath] else {
            pump()
            return
        }
        // A corpus of the build's configuration may have reached the store
        // while the build waited; nothing is printed for it then.
        if let summary = builtSummary(of: imagePath, transformer: build.transformer) {
            builds[imagePath] = nil
            build.subscribers.forEach { $0.continuation.resume(returning: summary) }
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

    /// The summary of the image's corpus under `transformer`, in memory or
    /// stored.
    private func builtSummary(of imagePath: String, transformer: Transformer.Configuration) -> RuntimeInterfaceCorpusBuildSummary? {
        if let corpus = corpora[imagePath], corpus.transformer == transformer {
            return corpus.summary
        }
        if let storedCorpus = storedCorpora[imagePath], storedCorpus.transformer == transformer {
            return storedCorpus.summary
        }
        return nil
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
            let corpus = await assembleCorpus(of: printsByObjectIndex.compactMap { $0 }, skippedCount: skippedCount, transformer: transformer)
            #log(.info, "Built corpus for \(imagePath, privacy: .public): \(corpus.entries.count, privacy: .public) objects, \(corpus.summary.byteCount, privacy: .public) bytes, \(skippedCount, privacy: .public) skipped, in \(Date().timeIntervalSince(start), privacy: .public) s")
            // Searchable from here on, and written before the build settles:
            // while the app waits on the build, the serving process works at
            // the app's priority, not at the background one it falls to when
            // nothing is asked of it.
            var isStored = false
            if installPrintedCorpus(corpus, imagePath: imagePath, buildIdentifier: buildIdentifier) {
                isStored = await storeAsDerivedData(corpus, imagePath: imagePath)
            }
            outcome = .built(corpus, isStored: isStored)
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

    /// The image's corpus out of its prints, the visibility conditions its
    /// entries repeat stored once. `nonisolated` so the pass — a walk over
    /// every interface of the image — runs off this actor, which stays free
    /// to answer searches and coverage meanwhile.
    private nonisolated func assembleCorpus(of prints: [RuntimeInterfaceCorpusPrint], skippedCount: Int, transformer: Transformer.Configuration) async -> ImageCorpus {
        ImageCorpus(sharingVisibilityConditionsOf: await assembleEntries(prints), skippedCount: skippedCount, transformer: transformer)
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
        case .built(let corpus, let isStored):
            restoredImages[imagePath] = nil
            failureMessages[imagePath] = nil
            if isStored {
                // On disk now: it stays in memory only if it fits.
                storedCorpora[imagePath] = StoredCorpus(transformer: corpus.transformer, summary: corpus.summary)
                admitIfRoom(corpus, imagePath: imagePath)
            } else {
                // Nowhere else to find it: kept, others evicted for it.
                storedCorpora[imagePath] = nil
                corpora[imagePath] = corpus
                enforceResidentLimit(protecting: imagePath)
            }
            build.subscribers.forEach { $0.continuation.resume(returning: corpus.summary) }
        case .failed(let error):
            failureMessages[imagePath] = "\(error)"
            build.subscribers.forEach { $0.continuation.resume(throwing: error) }
        case .cancelled:
            // Still the image's build yet cancelled: the builder went away.
            build.subscribers.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
    }

    // MARK: - Derived data

    /// Whether a build of the image begins by reading derived data.
    private func canRead(imagePath: String) -> Bool {
        derivedData?.imageDirectory(forImageAt: imagePath) != nil
    }

    /// Reads, off this actor, the summary stored for the image under
    /// `transformer`, then — when the corpus fits in the room left — the
    /// corpus itself, and settles build `buildIdentifier` with what it read;
    /// when nothing is stored, queues the build for the printer, or ends it
    /// when only restores were waiting.
    private func startRead(imagePath: String, buildIdentifier: UInt64, transformer: Transformer.Configuration) {
        guard let derivedData else { return }
        let readStoredSummary = readStoredSummary
        let startTime = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = await readStoredSummary(derivedData, imagePath, transformer)
            await self?.continueRead(imagePath: imagePath, buildIdentifier: buildIdentifier, transformer: transformer, summary: summary, startTime: startTime)
        }
    }

    /// The summary is in. A corpus that fits in the room left is read whole,
    /// so the first search finds it in memory; one that does not is built
    /// all the same — a search reads it back.
    private func continueRead(imagePath: String, buildIdentifier: UInt64, transformer: Transformer.Configuration, summary: RuntimeInterfaceCorpusBuildSummary?, startTime: UInt64) {
        guard let build = builds[imagePath], build.identifier == buildIdentifier, case .reading = build.phase else {
            #log(.info, "Dropping what the read of the stored corpus of \(imagePath, privacy: .public) brought back: its build was given up")
            return
        }
        guard let summary, let derivedData else {
            finishRead(imagePath: imagePath, buildIdentifier: buildIdentifier, read: nil, startTime: startTime)
            return
        }
        guard summary.byteCount <= roomLeft else {
            finishRead(imagePath: imagePath, buildIdentifier: buildIdentifier, read: .summary(summary), startTime: startTime)
            return
        }
        let readStoredCorpus = readStoredCorpus
        Task.detached(priority: .userInitiated) { [weak self] in
            // A corpus whose summary read but whose body does not is not
            // stored after all: the file is gone, and the build prints.
            let corpus = await readStoredCorpus(derivedData, imagePath, transformer)
            await self?.finishRead(imagePath: imagePath, buildIdentifier: buildIdentifier, read: corpus.map(StoredRead.corpus), startTime: startTime)
        }
    }

    /// The corpus `derivedData` holds for the image under `transformer`,
    /// checked and walked through; see `RuntimeInterfaceCorpusSnapshot`.
    static func readStoredCorpus(from derivedData: RuntimeDerivedDataStore, imagePath: String, transformer: Transformer.Configuration) async -> ImageCorpus? {
        await #signpostInterval("Read corpus from derived data") {
            await derivedData.read(.interfaceCorpus, variant: RuntimeInterfaceCorpusSnapshot.variant(for: transformer), forImageAt: imagePath) { container in
                try RuntimeInterfaceCorpusSnapshot.corpus(from: container, transformer: transformer)
            }
        }
    }

    /// What the corpus `derivedData` holds for the image under `transformer`
    /// holds, read from its summary section alone.
    static func readStoredSummary(from derivedData: RuntimeDerivedDataStore, imagePath: String, transformer: Transformer.Configuration) async -> RuntimeInterfaceCorpusBuildSummary? {
        await derivedData.read(
            .interfaceCorpus,
            variant: RuntimeInterfaceCorpusSnapshot.variant(for: transformer),
            forImageAt: imagePath,
            sections: RuntimeInterfaceCorpusSnapshot.summarySectionIdentifiers
        ) { container in
            try RuntimeInterfaceCorpusSnapshot.summary(from: container, transformer: transformer)
        }
    }

    private func finishRead(imagePath: String, buildIdentifier: UInt64, read: StoredRead?, startTime: UInt64) {
        guard var build = builds[imagePath], build.identifier == buildIdentifier, case .reading = build.phase else {
            #log(.info, "Dropping what the read of the stored corpus of \(imagePath, privacy: .public) brought back: its build was given up")
            return
        }
        if let read {
            builds[imagePath] = nil
            let duration = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000_000
            let summary: RuntimeInterfaceCorpusBuildSummary
            switch read {
            case .corpus(var corpus):
                corpus.lastSearchedAt = Date()
                summary = corpus.summary
                storedCorpora[imagePath] = StoredCorpus(transformer: corpus.transformer, summary: summary)
                let isResident = admitIfRoom(corpus, imagePath: imagePath)
                #log(.info, "Read the corpus of \(imagePath, privacy: .public) from derived data: \(corpus.entries.count, privacy: .public) objects, \(summary.byteCount, privacy: .public) bytes, in \(duration, privacy: .public) s\(isResident ? "" : "; no room left for it", privacy: .public)")
            case .summary(let storedSummary):
                summary = storedSummary
                storedCorpora[imagePath] = StoredCorpus(transformer: build.transformer, summary: summary)
                #log(.info, "The corpus of \(imagePath, privacy: .public) is in derived data: \(summary.objectCount, privacy: .public) objects, \(summary.byteCount, privacy: .public) bytes, left there for want of room")
            }
            let restoredImage = RuntimeInterfaceCorpusRestoredImage(summary: summary, duration: duration)
            restoredImages[imagePath] = restoredImage
            failureMessages[imagePath] = nil
            build.subscribers.forEach { $0.continuation.resume(returning: summary) }
            build.restoreSubscribers.forEach { $0.continuation.resume(returning: restoredImage) }
            return
        }
        let restoreSubscribers = build.restoreSubscribers
        build.restoreSubscribers = []
        restoreSubscribers.forEach { $0.continuation.resume(returning: nil) }
        guard !build.subscribers.isEmpty else {
            builds[imagePath] = nil
            return
        }
        build.phase = .printing
        let queueIndex = min(build.queueIndexAfterReading ?? pendingImagePaths.count, pendingImagePaths.count)
        builds[imagePath] = build
        pendingImagePaths.insert(imagePath, at: queueIndex)
        pump()
    }

    /// A printed corpus into the store while its build is still the
    /// image's: searchable now, settled once it is written. It may stand
    /// over the budget until then, evicting nothing: whether it stays is
    /// decided once it is known to be on disk (`finishBuild`). `false` for a
    /// build given up meanwhile, whose corpus is neither kept nor written.
    private func installPrintedCorpus(_ corpus: ImageCorpus, imagePath: String, buildIdentifier: UInt64) -> Bool {
        guard builds[imagePath]?.identifier == buildIdentifier else { return false }
        corpora[imagePath] = corpus
        restoredImages[imagePath] = nil
        failureMessages[imagePath] = nil
        return true
    }

    /// Writes `corpus` as the image's derived data, unless it printed
    /// addresses of this process, which the next launch would not find.
    /// Returns whether it is on disk.
    private func storeAsDerivedData(_ corpus: ImageCorpus, imagePath: String) async -> Bool {
        guard let derivedData, canRead(imagePath: imagePath) else { return false }
        guard let builder = await Self.containerBuilder(for: corpus, imagePath: imagePath) else { return false }
        return await derivedData.store(builder, as: .interfaceCorpus, variant: RuntimeInterfaceCorpusSnapshot.variant(for: corpus.transformer), forImageAt: imagePath)
    }

    @concurrent
    private static func containerBuilder(for corpus: ImageCorpus, imagePath: String) async -> RuntimeDerivedDataContainer.Builder? {
        if RuntimeInterfaceCorpusSnapshot.printsProcessAddresses(corpus) {
            #log(.info, "Not storing the corpus of \(imagePath, privacy: .public): it prints addresses of this process")
            return nil
        }
        do {
            return try RuntimeInterfaceCorpusSnapshot.containerBuilder(for: corpus)
        } catch {
            #log(.error, "Could not encode the corpus of \(imagePath, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Reads, for each of `imagePaths` in turn, the corpus derived data holds
    /// for it under `transformer`, without printing — the image need not be
    /// indexed. What is read is built at once, exactly as if by a build: the
    /// corpora that fit in the room left are read whole and stay in memory,
    /// in the order asked for, and once the budget is full only what each
    /// holds is read — a search reads them back. Returns the images read,
    /// each with what reading it took; an image already built from derived
    /// data under `transformer` is among them.
    ///
    /// An image whose build is printing is left to it; one whose build waits
    /// for the printer is read first, and goes back to its place in the
    /// queue when nothing is stored for it. Cancelling the calling task
    /// withdraws the request, and a read only it was waiting for.
    func restore(imagePaths: [String], transformer: Transformer.Configuration) async -> [String: RuntimeInterfaceCorpusRestoredImage] {
        guard derivedData != nil else { return [:] }
        var restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage] = [:]
        var askedImagePaths: Set<String> = []
        for imagePath in imagePaths where askedImagePaths.insert(imagePath).inserted {
            guard !Task.isCancelled else { break }
            restoredImagesByImagePath[imagePath] = await restore(imagePath: imagePath, transformer: transformer)
        }
        return restoredImagesByImagePath
    }

    private func restore(imagePath: String, transformer: Transformer.Configuration) async -> RuntimeInterfaceCorpusRestoredImage? {
        guard canRead(imagePath: imagePath) else { return nil }
        if let corpus = corpora[imagePath] {
            if corpus.transformer == transformer {
                return restoredImages[imagePath]
            }
            evict(imagePath: imagePath)
        } else if let storedCorpus = storedCorpora[imagePath] {
            if storedCorpus.transformer == transformer {
                return restoredImages[imagePath]
            }
            evict(imagePath: imagePath)
        }
        if let build = builds[imagePath], build.transformer != transformer {
            cancelBuild(imagePath: imagePath)
        }
        if var build = builds[imagePath], case .printing = build.phase {
            // In the slot, it is left to finish; in the queue, it is read
            // before the printer reaches it.
            guard let queueIndex = pendingImagePaths.firstIndex(of: imagePath) else { return nil }
            pendingImagePaths.remove(at: queueIndex)
            build.phase = .reading
            build.queueIndexAfterReading = queueIndex
            builds[imagePath] = build
            startRead(imagePath: imagePath, buildIdentifier: build.identifier, transformer: transformer)
        }

        nextSubscriberIdentifier += 1
        let identifier = nextSubscriberIdentifier
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let restoreSubscriber = RestoreSubscriber(identifier: identifier, continuation: continuation)
                if builds[imagePath] != nil {
                    builds[imagePath]!.restoreSubscribers.append(restoreSubscriber)
                } else {
                    nextBuildIdentifier += 1
                    builds[imagePath] = Build(identifier: nextBuildIdentifier, transformer: transformer, phase: .reading, restoreSubscribers: [restoreSubscriber])
                    startRead(imagePath: imagePath, buildIdentifier: nextBuildIdentifier, transformer: transformer)
                }
            }
        } onCancel: {
            Task { await self.unsubscribeRestore(imagePath: imagePath, identifier: identifier) }
        }
    }

    // MARK: - Eviction

    /// Forgets the image's corpus, in memory and stored — a search no longer
    /// reads it back — and cancels its build.
    func evict(imagePath: String) {
        corpora[imagePath] = nil
        storedCorpora[imagePath] = nil
        restoredImages[imagePath] = nil
        failureMessages[imagePath] = nil
        cancelBuild(imagePath: imagePath)
    }

    /// `evict(imagePath:)` for every image.
    func evictAll() {
        corpora.removeAll()
        storedCorpora.removeAll()
        restoredImages.removeAll()
        failureMessages.removeAll()
        cancelEveryBuild()
    }

    /// Frees the memory the corpora take — the Report navigator's Eject.
    /// The corpora derived data holds stay built, read back by the next
    /// search that needs them; every other one is dropped. Every build and
    /// read under way is cancelled, as by `evictAll()`.
    func evictResidentCorpora() {
        for imagePath in corpora.keys where storedCorpora[imagePath] == nil {
            restoredImages[imagePath] = nil
        }
        corpora.removeAll()
        cancelEveryBuild()
    }

    private func cancelEveryBuild() {
        for imagePath in Array(builds.keys) {
            cancelBuild(imagePath: imagePath)
        }
    }

    func setResidentByteLimit(_ limit: Int) {
        residentByteLimit = max(0, limit)
        enforceResidentLimit(protecting: nil)
    }

    /// Evicts until the corpora in memory fit the budget: first the ones
    /// derived data holds, which stay built, then the others, which go back
    /// to unbuilt — each group least recently searched first, and never
    /// `protectedImagePath`.
    private func enforceResidentLimit(protecting protectedImagePath: String?) {
        while residentByteCount > residentByteLimit {
            let candidates = corpora.filter { $0.key != protectedImagePath }
            let storedCandidates = candidates.filter { storedCorpora[$0.key] != nil }
            let pool = storedCandidates.isEmpty ? candidates : storedCandidates
            guard let oldest = pool.min(by: { $0.value.lastSearchedAt < $1.value.lastSearchedAt }) else { return }
            #log(.info, "Evicting the corpus of \(oldest.key, privacy: .public) (\(oldest.value.summary.byteCount, privacy: .public) bytes) to stay under \(self.residentByteLimit, privacy: .public) bytes")
            corpora[oldest.key] = nil
            if storedCorpora[oldest.key] == nil {
                restoredImages[oldest.key] = nil
            }
        }
    }

    /// Keeps `corpus` in memory if it fits in the room the budget has left,
    /// evicting nothing — how builds and restores fill the budget, in the
    /// order they finish: which corpora stay beyond that is for searches to
    /// decide. One that does not fit is taken out of memory if it was there.
    @discardableResult
    private func admitIfRoom(_ corpus: ImageCorpus, imagePath: String) -> Bool {
        let othersByteCount = residentByteCount - (corpora[imagePath]?.summary.byteCount ?? 0)
        guard othersByteCount + corpus.summary.byteCount <= residentByteLimit else {
            corpora[imagePath] = nil
            return false
        }
        corpora[imagePath] = corpus
        return true
    }

    /// Keeps a corpus a search read back if it fits once the stored corpora
    /// last searched before that search began are evicted, least recently
    /// searched first. Never evicts a corpus the same search reads — they
    /// are as recent — nor one that cannot be read back. One that would not
    /// fit even then is left on disk.
    private func admitSearched(_ corpus: ImageCorpus, imagePath: String, searchedAt: Date) {
        let byteCount = corpus.summary.byteCount
        var room = residentByteLimit - residentByteCount
        var evictedImagePaths: [String] = []
        if room < byteCount {
            let candidates = corpora
                .filter { storedCorpora[$0.key] != nil && $0.value.lastSearchedAt < searchedAt }
                .sorted { $0.value.lastSearchedAt < $1.value.lastSearchedAt }
            for (candidateImagePath, candidate) in candidates where room < byteCount {
                evictedImagePaths.append(candidateImagePath)
                room += candidate.summary.byteCount
            }
            guard room >= byteCount else { return }
        }
        for evictedImagePath in evictedImagePaths {
            #log(.info, "Evicting the corpus of \(evictedImagePath, privacy: .public) for \(imagePath, privacy: .public), searched since")
            corpora[evictedImagePath] = nil
        }
        var keptCorpus = corpus
        keptCorpus.lastSearchedAt = searchedAt
        corpora[imagePath] = keptCorpus
    }

    // MARK: - Searching

    /// One image as a search reads it, taken on this actor so the scan can
    /// run off it: its corpus in memory, or the configuration its stored
    /// corpus is read back under when the scan reaches it. The entries are
    /// values: a corpus evicted while the scan runs stays readable — and
    /// resident, over the budget — until the scan is done with it.
    private enum SearchSource: Sendable {
        case resident(imagePath: String, entries: [RuntimeInterfaceCorpusEntry])
        case stored(imagePath: String, transformer: Transformer.Configuration)

        var imagePath: String {
            switch self {
            case .resident(let imagePath, _), .stored(let imagePath, _):
                imagePath
            }
        }
    }

    /// What the scan of one search came to.
    private struct SearchScan: Sendable {
        var totalMatchCount = 0
        var omittedRepeatedMatchCount = 0
        var collectedCount = 0
        var scannedObjectCount = 0
        var scannedImagePaths: [String] = []
        var stopReason: RuntimeInterfaceSearchStopReason?
    }

    /// Runs `query` over every built corpus, pushing matches to `onProgress`
    /// one image at a time, and returns the summary. A stored corpus out of
    /// memory is read back when the scan reaches it, one at a time. Matches
    /// are collected up
    /// to `query.resultLimit`; the count goes on past it. The scan runs off
    /// this actor, so whatever the pattern costs, the store keeps answering;
    /// a regular expression that spends the search's budget stops it, with
    /// what was delivered standing and the summary saying why. An
    /// Objective-C protocol copy that reads exactly like one already
    /// reported is only counted — see `scan`.
    func searchInterfaces(
        _ query: RuntimeInterfaceSearchQuery,
        indexedImagePaths: Set<String>,
        onProgress: @Sendable ([RuntimeInterfaceSearchMatch]) async -> Void
    ) async throws -> RuntimeInterfaceSearchSummary {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
        let visibility = query.generationOptions.map(RuntimeInterfaceVisibility.init)
        let searchedAt = Date()
        let scan = try await Self.scan(
            sourcesToSearch(within: query.imagePaths, searchedAt: searchedAt),
            resultLimit: query.resultLimit,
            regularExpressionTimeLimit: regularExpressionTimeLimit,
            readBack: { imagePath, transformer in
                await self.readBack(imagePath: imagePath, transformer: transformer, searchedAt: searchedAt)
            },
            onProgress: onProgress
        ) { entry, budget, isCollecting, reportsHits, collect in
            // Most entries have no hit at all; under options that hide
            // something, learn that before paying for the projection.
            if let visibility, !entry.visibilityRegions.isEmpty, !entry.mayHaveHits(of: pattern, under: visibility) {
                return 0
            }
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
            // The text is at hand, so a repeated protocol copy is told before
            // its hits are looked for, and then only counted.
            let isReported = reportsHits(interface.text)
            return try RuntimeInterfaceTextMatcher.matches(in: interface, object: entry.object, pattern: pattern, budget: &budget, excludingUTF8Ranges: nestedDefinitionRanges, isCollecting: isCollecting && isReported, collect: collect)
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
        let searchedAt = Date()
        let scan = try await Self.scan(
            sourcesToSearch(within: query.imagePaths, searchedAt: searchedAt),
            resultLimit: query.resultLimit,
            regularExpressionTimeLimit: regularExpressionTimeLimit,
            readBack: { imagePath, transformer in
                await self.readBack(imagePath: imagePath, transformer: transformer, searchedAt: searchedAt)
            },
            onProgress: onProgress
        ) { entry, budget, isCollectingAtStart, reportsHits, collect in
            guard let pattern else { return 0 }
            var matchCount = 0
            var isCollecting = isCollectingAtStart
            // Whether a repeated protocol copy is only counted is settled at
            // the entry's first match, once the text it reads as is known.
            var isReported: Bool?
            // Projected only once a member of this entry matches: most
            // entries have none, and they cost nothing.
            var projection: (projection: VisibilityProjection, lineTable: RuntimeInterfaceLineTable)??
            for (memberIndex, member) in entry.members.enumerated() {
                if let kinds, !kinds.contains(member.kind) { continue }
                guard let range = try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: member.name, pattern: pattern, budget: &budget) else { continue }
                var projectedMember: RuntimeMemberDeclaration?
                if let visibility {
                    if projection == nil {
                        projection = entry.projection(under: visibility).map { ($0, RuntimeInterfaceLineTable($0.text.text)) }
                    }
                    if let entryProjection = projection ?? nil {
                        // Hidden under the query's options: not a match.
                        guard let memberUnderOptions = entry.member(at: memberIndex, in: entryProjection.projection, projectedLineTable: entryProjection.lineTable) else { continue }
                        projectedMember = memberUnderOptions
                    }
                }
                if isReported == nil {
                    let reported = reportsHits((projection ?? nil)?.projection.text.text ?? entry.interface.text)
                    isReported = reported
                    isCollecting = isCollecting && reported
                }
                matchCount += 1
                if isCollecting {
                    // The line is read back out of the text only for a member collected.
                    isCollecting = collect(RuntimeMemberMatch(object: entry.object, member: projectedMember ?? entry.displayedMember(at: memberIndex), matchRangeInName: range))
                }
            }
            return matchCount
        }
        return summary(of: scan, indexedImagePaths: indexedImagePaths, within: query.imagePaths)
    }

    /// The built images a search reads, in path order — all of them, or
    /// those of `scope` when the query names some — the ones in memory
    /// marked searched at `searchedAt`.
    private func sourcesToSearch(within scope: Set<String>?, searchedAt: Date) -> [SearchSource] {
        var imagePaths = Set(corpora.keys).union(storedCorpora.keys).sorted()
        if let scope {
            imagePaths = imagePaths.filter(scope.contains)
        }
        return imagePaths.compactMap { imagePath in
            if let corpus = corpora[imagePath] {
                corpora[imagePath]?.lastSearchedAt = searchedAt
                return .resident(imagePath: imagePath, entries: corpus.entries)
            }
            guard let storedCorpus = storedCorpora[imagePath] else { return nil }
            return .stored(imagePath: imagePath, transformer: storedCorpus.transformer)
        }
    }

    /// The entries of a stored corpus the scan of a search has reached, read
    /// off this actor and kept in memory if `admitSearched` finds room. `nil`
    /// when its file is gone or fails its checks: the image is no longer
    /// built, and its failure says why.
    private func readBack(imagePath: String, transformer: Transformer.Configuration, searchedAt: Date) async -> [RuntimeInterfaceCorpusEntry]? {
        // In memory by now — read back for another search, or built.
        if let corpus = corpora[imagePath], corpus.transformer == transformer {
            corpora[imagePath]?.lastSearchedAt = searchedAt
            return corpus.entries
        }
        guard let derivedData else { return nil }
        let corpus = await readStoredCorpus(derivedData, imagePath, transformer)
        // Still the image's stored corpus, still out of memory: evicted or
        // rebuilt meanwhile, it is not the store's to keep or forget.
        let isStillStored = storedCorpora[imagePath]?.transformer == transformer && corpora[imagePath] == nil
        guard let corpus else {
            if isStillStored {
                #log(.error, "Could not read back the stored corpus of \(imagePath, privacy: .public); it is no longer searchable")
                storedCorpora[imagePath] = nil
                restoredImages[imagePath] = nil
                failureMessages[imagePath] = "Its stored corpus could not be read back from derived data."
            }
            return nil
        }
        if isStillStored {
            admitSearched(corpus, imagePath: imagePath, searchedAt: searchedAt)
        }
        return corpus.entries
    }

    /// Reads `sources` entry by entry, off this actor, a stored corpus read
    /// back through `readBack` when the scan reaches it — an image it cannot
    /// read is passed over, and is not among the images scanned. The text
    /// and member searches differ only in `matchEntry`, which hands each
    /// match of an entry to its last argument — `false` back means the result
    /// limit is reached and nothing more is taken — and returns how many
    /// matches the entry has. Its third argument says whether anything is still taken
    /// when the entry starts; past the limit an entry is only counted, which
    /// needs much less work. One regular expression budget serves the whole
    /// search.
    ///
    /// Its fourth argument folds repeated Objective-C protocol copies. An
    /// image carries a copy of every protocol it saw declared, so a search
    /// over several images meets the same declaration once per carrier;
    /// `matchEntry` calls it once, no later than its first match, with the
    /// text the entry reads as under the search's options. `false` back
    /// means the entry is a protocol copy that reads exactly like one this
    /// search already reported hits in: its matches are then only counted,
    /// into `omittedRepeatedMatchCount` instead of the total. Corpora are
    /// read in path order, so the copy shown is the first image's.
    ///
    /// Checks for cancellation before every entry and before an image's
    /// batch goes out, so a cancelled search delivers nothing more; the
    /// regular expression engine looks at the task itself in between. Yields
    /// after every image. A regular expression that spends the budget ends
    /// the scan where it is: the matches of the image under way still go
    /// out, and `stopReason` says why nothing follows.
    @concurrent
    private static func scan<Match: Sendable>(
        _ sources: [SearchSource],
        resultLimit: Int,
        regularExpressionTimeLimit: TimeInterval,
        readBack: @Sendable (_ imagePath: String, _ transformer: Transformer.Configuration) async -> [RuntimeInterfaceCorpusEntry]?,
        onProgress: @Sendable ([Match]) async -> Void,
        matchEntry: @Sendable (_ entry: RuntimeInterfaceCorpusEntry, _ budget: inout RuntimeInterfaceTextMatcher.RegularExpressionBudget, _ isCollecting: Bool, _ reportsHits: (_ shownText: String) -> Bool, _ collect: (Match) -> Bool) throws -> Int
    ) async throws -> SearchScan {
        var scan = SearchScan()
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: regularExpressionTimeLimit)
        var repeatedProtocolCopies = RuntimeInterfaceRepeatedProtocolCopies()
        for source in sources {
            try Task.checkCancellation()
            let entries: [RuntimeInterfaceCorpusEntry]
            switch source {
            case .resident(_, let residentEntries):
                entries = residentEntries
            case .stored(let imagePath, let transformer):
                // Read one image at a time: what is not kept goes once its
                // scan is done, before the next is read.
                guard let readEntries = await readBack(imagePath, transformer) else { continue }
                try Task.checkCancellation()
                entries = readEntries
            }
            scan.scannedImagePaths.append(source.imagePath)
            var batch: [Match] = []
            var collectedCount = scan.collectedCount
            do {
                for entry in entries {
                    try Task.checkCancellation()
                    scan.scannedObjectCount += 1
                    var isRepeatedCopy = false
                    var shownText: String?
                    let matchCount = try matchEntry(entry, &budget, collectedCount < resultLimit, { text in
                        isRepeatedCopy = repeatedProtocolCopies.isRepeated(entry, readingAs: text)
                        shownText = text
                        return !isRepeatedCopy
                    }) { match in
                        guard collectedCount < resultLimit else { return false }
                        batch.append(match)
                        collectedCount += 1
                        return collectedCount < resultLimit
                    }
                    if isRepeatedCopy {
                        scan.omittedRepeatedMatchCount += matchCount
                    } else {
                        scan.totalMatchCount += matchCount
                        if matchCount > 0, let shownText {
                            repeatedProtocolCopies.recordReported(entry, readingAs: shownText)
                        }
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
            stopReason: scan.stopReason,
            omittedRepeatedMatchCount: scan.omittedRepeatedMatchCount
        )
    }

    /// The indexed images a search could not read for want of a corpus, of
    /// those it was asked to cover: all of them, or those of `scope`.
    private func unbuiltImagePaths(among indexedImagePaths: Set<String>, within scope: Set<String>?) -> [String] {
        let coveredImagePaths = scope.map(indexedImagePaths.intersection) ?? indexedImagePaths
        return coveredImagePaths.filter { !isBuilt($0) }.sorted()
    }
}

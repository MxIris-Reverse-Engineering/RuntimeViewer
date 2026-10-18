#if arch(arm64)
import Testing
import Foundation
import ObjectiveC
import RuntimeViewerCore
import CrossReferenceAnalysis
@testable import RuntimeViewerCrossReferences

/// Queries against the dyld shared cache this process maps — the same code
/// the engine's process reads in the app. Addresses come from the cache itself,
/// never written down; what a few tests expect a function to send or call is
/// macOS 27.2's code, and moves when an update compiles it differently.
@Suite("Cross-reference queries")
struct CrossReferenceQueryTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
    private static let coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// Built once: an analyzer is a snapshot, and these tests only need to
    /// look addresses up in it.
    private static let analyzer = CrossReferenceAnalyzer()!

    private static func address(of symbol: String, inImageAt path: String) throws -> UInt64 {
        let imageIndex = try #require(CrossReferenceQuery.imageIndex(forPath: path, in: analyzer))
        let function = try #require(analyzer.functions(inImageAt: imageIndex).first { function in
            function.name == .symbol(symbol) || function.foldedSymbolNames.contains(symbol)
        })
        return function.location.address
    }

    /// As many scans at once as the machine has cores: these tests are about
    /// what a query finds, and a few at a time would only slow them down.
    /// `scansRunAFewAtATimeOffTheThreadPool` covers the limit.
    private static let testMaximumConcurrentScans = ProcessInfo.processInfo.activeProcessorCount

    /// A query reading `indexedImagePaths` as the images its engine has
    /// indexed — by default every image this process had when the tests
    /// started.
    private static func makeQuery(
        session: CrossReferenceSession = CrossReferenceSession(maximumConcurrentScans: testMaximumConcurrentScans),
        indexedImagePaths: [String] = analyzer.imagePaths
    ) -> CrossReferenceQuery {
        CrossReferenceQuery(engine: RuntimeEngine(source: .local, engineID: "test-cross-reference-queries"), session: session) { indexedImagePaths }
    }

    /// Collects a query's progress reports.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RuntimeCrossReferenceQueryProgress] = []

        var reports: [RuntimeCrossReferenceQueryProgress] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ progress: RuntimeCrossReferenceQueryProgress) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(progress)
        }
    }

    // MARK: - Callees

    @Test("Callees of an Objective-C method: its sends, named, with the helpers hidden")
    func calleesOfAnObjectiveCMethod() async throws {
        let address = try Self.address(of: "-[NSWindow makeKeyAndOrderFront:]", inImageAt: Self.appKitPath)
        let engine = RuntimeEngine(source: .local, engineID: "test-cross-reference-callees")
        let subject = RuntimeCrossReferenceSubject.function(imagePath: Self.appKitPath, address: address)

        let result = try await engine.callees(of: subject)
        #expect(result.isComplete)
        #expect(result.references.allSatisfy { $0.referencingFunction.displayName == "-[NSWindow makeKeyAndOrderFront:]" })
        let sendsOrderWindow = result.references.contains { reference in
            guard case .selector("orderWindow:relativeTo:", _) = reference.target else { return false }
            return reference.kind == .messageSend
        }
        #expect(sendsOrderWindow)
        #expect(!result.references.contains { $0.isRuntimeHelperCall })
        // `[self orderWindow:… relativeTo:…]`: a send to the method's own
        // receiver, so to an NSWindow, and exact.
        let orderWindow = result.references.first { reference in
            guard case .selector("orderWindow:relativeTo:", _) = reference.target else { return false }
            return true
        }
        #expect(orderWindow?.target == .selector(name: "orderWindow:relativeTo:", receiverClassName: "NSWindow"))
        #expect(orderWindow?.precision == .exact)

        let withHelpers = try await engine.callees(of: subject, options: RuntimeCrossReferenceQueryOptions(includesRuntimeHelperCalls: true))
        #expect(withHelpers.references.count >= result.references.count)
        #expect(Set(result.references).isSubset(of: Set(withHelpers.references)))
    }

    @Test("A selector has no callees, an unknown image and an address outside every function are errors")
    func calleeErrors() async throws {
        let query = Self.makeQuery()
        await #expect(throws: RuntimeCrossReferenceError.selectorHasNoCallees("count")) {
            try await query.callees(of: .selector("count"), options: RuntimeCrossReferenceQueryOptions())
        }
        await #expect(throws: RuntimeCrossReferenceError.imageNotFound(path: "/nowhere/libNothing.dylib")) {
            try await query.callees(of: .function(imagePath: "/nowhere/libNothing.dylib", address: 0x1000), options: RuntimeCrossReferenceQueryOptions())
        }
        await #expect(throws: RuntimeCrossReferenceError.functionNotFound(imagePath: Self.libobjcPath, address: 1)) {
            try await query.callees(of: .function(imagePath: Self.libobjcPath, address: 1), options: RuntimeCrossReferenceQueryOptions())
        }
    }

    @Test("A function of an image outside the shared cache — this test bundle — is found by the path dyld loaded it from")
    func imagesOutsideTheCacheGoByTheirLoadedPath() async throws {
        var information = Dl_info()
        #expect(dladdr(#dsohandle, &information) != 0)
        let path = String(cString: try #require(information.dli_fname))
        let analyzer = try #require(CrossReferenceAnalyzer())
        let testBundle = try #require(analyzer.images.firstIndex { $0.ptr == #dsohandle })
        let function = try #require(analyzer.functions(inImageAt: testBundle).first { $0.size >= 64 })
        let result = try await Self.makeQuery().callees(of: .function(imagePath: path, address: function.location.address), options: RuntimeCrossReferenceQueryOptions())
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.referencingFunction.imagePath == path })
    }

    @Test("An Objective-C method found as a caller carries its member: the selector of the class that defines it")
    func objectiveCCallersCarryTheirMember() async throws {
        let result = try await Self.makeQuery().callers(of: .selector("appendString:"), in: .image(path: Self.foundationPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let methodCallers = result.references.map(\.referencingFunction).filter { $0.displayName?.hasPrefix("-[") == true || $0.displayName?.hasPrefix("+[") == true }
        try #require(!methodCallers.isEmpty)
        for caller in methodCallers {
            let member = try #require(caller.member, "\(caller.displayName ?? "") maps to no member")
            #expect(member.kind == .objcMethod)
            #expect(member.object.kind == .objc(.type(.class)))
            // A category method keeps its category in the name, not in the member: the class has it.
            let displayName = try #require(caller.displayName)
            #expect(displayName.hasPrefix("\(member.isStatic ? "+" : "-")[\(member.object.name)"))
            #expect(displayName.hasSuffix(" \(member.name)]"))
        }
        // The member's type is in the image defining the class — Foundation for its own classes,
        // libobjc for a Foundation category on `NSObject` — as the runtime of this process, which
        // has both loaded, says.
        var checkedClassCount = 0
        for caller in methodCallers {
            guard let member = caller.member, let classObject = objc_lookUpClass(member.object.name), let classImageName = class_getImageName(classObject) else { continue }
            #expect(member.object.imagePath == String(cString: classImageName), "\(caller.displayName ?? "")")
            checkedClassCount += 1
        }
        #expect(checkedClassCount > 0)
    }

    @Test("A cache image named through its framework's symlinks — whose target only the shared cache holds — is found")
    func imagesNamedThroughFrameworkSymlinksAreFound() async throws {
        // `Foundation.framework/Foundation` points at `Versions/C/Foundation`, which is no file:
        // the file system cannot resolve the link, dyld can.
        let symlinkedPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        #expect(URL(fileURLWithPath: symlinkedPath).resolvingSymlinksInPath().path == symlinkedPath)
        let result = try await Self.makeQuery().callers(of: .selector("appendString:"), in: .image(path: symlinkedPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        #expect(!result.references.isEmpty)
    }

    // MARK: - Callers

    @Test("Callers of a selector in one image are exactly its sends, and the reports add up to the result")
    func callersOfASelectorInOneImage() async throws {
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery().callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { progress in
            recorder.record(progress)
        }
        #expect(result.isComplete)
        #expect(result.references.contains { $0.referencingFunction.displayName == "-[NSWindow makeKeyAndOrderFront:]" })
        #expect(result.references.allSatisfy { $0.precision == .exact })
        #expect(result.references.allSatisfy { $0.kind == .messageSend || $0.kind == .superMessageSend })
        #expect(result.references.allSatisfy { $0.referencingFunction.imagePath == Self.appKitPath })

        let reports = recorder.reports
        #expect(reports.last?.scannedImageCount == 1)
        #expect(reports.last?.totalImageCount == 1)
        #expect(Set(reports.flatMap(\.references)) == Set(result.references))
        #expect(reports.flatMap(\.references).count == result.references.count)
    }

    @Test("Calls through another image's stubs resolve to the function they reach")
    func callersAcrossImagesResolveThroughStubs() async throws {
        let address = try Self.address(of: "_CFRelease", inImageAt: Self.coreFoundationPath)
        let result = try await Self.makeQuery().callers(
            of: .function(imagePath: Self.coreFoundationPath, address: address),
            in: .image(path: Self.foundationPath),
            options: RuntimeCrossReferenceQueryOptions(),
            reportProgress: { _ in }
        )
        #expect(!result.references.isEmpty)
        for reference in result.references {
            #expect(reference.referencingFunction.imagePath == Self.foundationPath)
            #expect(reference.kind == .call || reference.kind == .tailCall)
            #expect(reference.precision == .exact)
            switch reference.target {
            case .function(let function):
                #expect(function.imagePath == Self.coreFoundationPath)
                #expect(function.address == address)
                #expect(function.displayName == "CFRelease")
            case .importedSymbol(let name):
                #expect(name == "_CFRelease")
            default:
                Issue.record("Unexpected target \(reference.target)")
            }
        }
    }

    @Test("Callers across the indexed images are prefiltered: a selector few images send scans few images")
    func callersAcrossIndexedImagesArePrefiltered() async throws {
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery().callers(
            of: .selector("orderWindow:relativeTo:"),
            in: .indexedImages,
            options: RuntimeCrossReferenceQueryOptions(),
            reportProgress: { recorder.record($0) }
        )
        #expect(result.isComplete)
        let total = try #require(recorder.reports.last?.totalImageCount)
        #expect(total > 0)
        #expect(total < Self.analyzer.imagePaths.count / 10)
        #expect(result.references.contains { $0.referencingFunction.imagePath == Self.appKitPath })
    }

    @Test("A query across the indexed images scans those alone, however many other images could reference the subject")
    func indexedImagesBoundTheScan() async throws {
        // About a hundred images send it; only AppKit is indexed.
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery(indexedImagePaths: [Self.appKitPath]).callers(
            of: .selector("makeKeyAndOrderFront:"),
            in: .indexedImages,
            options: RuntimeCrossReferenceQueryOptions()
        ) { recorder.record($0) }
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.referencingFunction.imagePath == Self.appKitPath })
        #expect(!recorder.reports.isEmpty)
        #expect(recorder.reports.allSatisfy { $0.totalImageCount == 1 })
    }

    @Test("An image that is not indexed is refused, not scanned")
    func imagesNotIndexedAreRefused() async throws {
        let query = Self.makeQuery(indexedImagePaths: [Self.appKitPath])
        await #expect(throws: RuntimeCrossReferenceError.imageNotIndexed(path: Self.foundationPath)) {
            try await query.callers(of: .selector("appendString:"), in: .image(path: Self.foundationPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        }
        let window = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: Self.appKitPath, children: [])
        await #expect(throws: RuntimeCrossReferenceError.imageNotIndexed(path: Self.foundationPath)) {
            try await query.typeReferences(to: window, in: .image(path: Self.foundationPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        }
    }

    @Test("A limit stops the scan with exactly that many references")
    func limitStopsTheScan() async throws {
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery().callers(
            of: .selector("init"),
            in: .indexedImages,
            options: RuntimeCrossReferenceQueryOptions(resultLimit: 100),
            reportProgress: { recorder.record($0) }
        )
        #expect(result.references.count == 100)
        #expect(!result.isComplete)
        #expect(recorder.reports.flatMap(\.references).count == 100)
        let last = try #require(recorder.reports.last)
        #expect(last.scannedImageCount < last.totalImageCount)
    }

    @Test("Cancelling the caller stops a scan of thousands of images")
    func cancellationStopsTheScan() async throws {
        let query = Self.makeQuery()
        let recorder = ProgressRecorder()
        let (firstReport, firstReportContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await query.callers(of: .selector("init"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { progress in
                recorder.record(progress)
                firstReportContinuation.yield()
            }
        }
        for await _ in firstReport { break }
        task.cancel()
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        let last = try #require(recorder.reports.last)
        #expect(last.scannedImageCount < last.totalImageCount)
    }

    @Test("A Swift function's callers are looked for in every image linking its own")
    func swiftFunctionCandidatesFollowTheLinkage() throws {
        // The macOS 27.2 cache keeps no Swift symbol among most of its images'
        // undefined symbols: a prefilter by imports kept a few images that do
        // and dropped every caller in the rest — MachOSwiftSection's
        // `swiftFunctionPrefilterKeepsEveryCaller` samples which.
        let symbol = "_$s10Foundation3URLV4pathSSvg"
        let address = try Self.address(of: symbol, inImageAt: Self.foundationPath)
        let foundation = try #require(CrossReferenceQuery.imageIndex(forPath: Self.foundationPath, in: Self.analyzer))
        let function = try #require(Self.analyzer.function(containing: CodeLocation(imageIndex: foundation, address: address)))
        let subject = CrossReferenceQuery.ResolvedSubject(functions: [.init(function: function, member: nil)])
        let candidates = Set(try Self.makeQuery().candidateImages(for: subject, in: .indexedImages, among: Set(Self.analyzer.imagePaths.indices), analyzer: Self.analyzer))
        let everyImage = Self.analyzer.imagePaths.indices
        let linkers = Set(Self.analyzer.imageIndices(linkingImageAt: foundation, among: everyImage))
        #expect(linkers.isSubset(of: candidates))
        #expect(candidates.count > Self.analyzer.imageIndices(importing: symbol, among: everyImage).count)
    }

    // MARK: - Type references

    private static let swiftUICorePath = "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore"

    @Test("References to an Objective-C class in its own image: exact, and pointing at the class")
    func typeReferencesOfAnObjectiveCClass() async throws {
        let window = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: Self.appKitPath, children: [])
        let result = try await Self.makeQuery().typeReferences(to: window, in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions(), reportProgress: { _ in })
        #expect(result.isComplete)
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.kind == .typeReference && $0.precision == .exact })
        #expect(result.references.allSatisfy { $0.target == .type(name: "NSWindow", object: window) })
        #expect(result.references.allSatisfy { $0.referencingFunction.imagePath == Self.appKitPath })
    }

    @Test("References to a Swift type, which Runtime Viewer names by the key the analysis uses")
    func typeReferencesOfASwiftType() async throws {
        let text = RuntimeObject(name: "7SwiftUI4TextV", displayName: "Text", kind: .swift(.type(.struct)), imagePath: Self.swiftUICorePath, children: [])
        let result = try await Self.makeQuery().typeReferences(to: text, in: .image(path: Self.swiftUICorePath), options: RuntimeCrossReferenceQueryOptions(), reportProgress: { _ in })
        #expect(result.isComplete)
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.kind == .typeReference && $0.target == .type(name: "Text", object: text) })
    }

    @Test("A Swift type's references are looked for in every image linking its own")
    func typeCandidatesFollowTheLinkage() throws {
        // Few shared cache images keep a Swift symbol among their undefined
        // ones; a prefilter by imports would keep those and drop the rest.
        let url = RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: Self.foundationPath, children: [])
        let type = try Self.makeQuery().resolveType(url, with: Self.analyzer)
        let everyImage = Self.analyzer.imagePaths.indices
        let candidates = Set(type.candidateImages(among: everyImage, analyzer: Self.analyzer))
        let foundation = try #require(CrossReferenceQuery.imageIndex(forPath: Self.foundationPath, in: Self.analyzer))
        #expect(Set(Self.analyzer.imageIndices(linkingImageAt: foundation, among: everyImage)).isSubset(of: candidates))
    }

    @Test("A Swift type's references are found in an image that imports nothing for it")
    func typeReferencesWithoutAnImport() async throws {
        // SharedWithYou calls `URL`'s metadata accessor through a GOT stub the
        // cache builder bound, and keeps no undefined symbol for it.
        let sharedWithYou = "/System/Library/Frameworks/SharedWithYou.framework/Versions/A/SharedWithYou"
        let url = RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: Self.foundationPath, children: [])
        let result = try await Self.makeQuery().typeReferences(to: url, in: .image(path: sharedWithYou), options: RuntimeCrossReferenceQueryOptions(), reportProgress: { _ in })
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.referencingFunction.imagePath == sharedWithYou && $0.target == .type(name: "URL", object: url) })
    }

    @Test("A type reference carries the type, not its nested types")
    func typeReferencesCarryNoChildren() async throws {
        let formatStyle = RuntimeObject(name: "10Foundation3URLV11FormatStyleV", displayName: "URL.FormatStyle", kind: .swift(.type(.struct)), imagePath: Self.foundationPath, children: [])
        let url = RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: Self.foundationPath, children: [formatStyle])
        let result = try await Self.makeQuery().typeReferences(to: url, in: .image(path: Self.foundationPath), options: RuntimeCrossReferenceQueryOptions(), reportProgress: { _ in })
        #expect(!result.references.isEmpty)
        for reference in result.references {
            guard case .type(_, let object?) = reference.target else {
                Issue.record("Unexpected target \(reference.target)")
                continue
            }
            #expect(object == url)
            #expect(object.children.isEmpty)
        }
    }

    @Test("An internal Swift type's references are looked for in its own image alone")
    func internalSwiftTypesScanTheirOwnImage() async throws {
        // AppKit exports no symbol of this struct: no other image can reach it.
        let suggestion = RuntimeObject(name: "6AppKit23NSSmartNamingSuggestionV", displayName: "AppKit.NSSmartNamingSuggestion", kind: .swift(.type(.struct)), imagePath: Self.appKitPath, children: [])
        let recorder = ProgressRecorder()
        _ = try await Self.makeQuery().typeReferences(to: suggestion, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { recorder.record($0) }
        #expect(!recorder.reports.isEmpty)
        #expect(recorder.reports.allSatisfy { $0.totalImageCount == 1 })
    }

    @Test("A protocol is no type whose references are found")
    func typeReferencesNeedAType() async throws {
        let copying = RuntimeObject(name: "NSCopying", displayName: "NSCopying", kind: .objc(.type(.protocol)), imagePath: "/usr/lib/libobjc.A.dylib", children: [])
        await #expect(throws: RuntimeCrossReferenceError.typeNotFound(objectName: "NSCopying")) {
            try await Self.makeQuery().typeReferences(to: copying, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions(), reportProgress: { _ in })
        }
    }

    @Test("A repeated type query reuses the scan")
    func typeScansAreReused() async throws {
        let session = Self.makeSteadySession()
        let query = Self.makeQuery(session: session)
        let window = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: Self.appKitPath, children: [])
        let firstRecorder = ProgressRecorder()
        let first = try await query.typeReferences(to: window, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { firstRecorder.record($0) }
        // A report per image scanned: the scan covered more than one.
        #expect(firstRecorder.reports.count > 1)
        let recorder = ProgressRecorder()
        let second = try await query.typeReferences(to: window, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { recorder.record($0) }
        #expect(second == first)
        // One report, for every image found among the earlier scans.
        #expect(recorder.reports.count == 1)
    }

    // MARK: - Session

    /// A session whose images never change: another test in the process may
    /// load an image outside the cache (the Objective-C runtime loads
    /// `libobjc-trampolines.dylib` on first use), which would start a new
    /// generation and drop every scan these tests count on.
    private static func makeSteadySession(
        scanByteBudget: Int = CrossReferenceSession.defaultScanByteBudget,
        maximumConcurrentScans: Int = testMaximumConcurrentScans
    ) -> CrossReferenceSession {
        CrossReferenceSession(scanByteBudget: scanByteBudget, maximumConcurrentScans: maximumConcurrentScans, imagesOutsideSharedCache: { [] })
    }

    /// Watches scans run: how many at once at most, at which priorities, and
    /// whether any ran on a thread of the Swift concurrency pool.
    private final class ScanObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var runningCount = 0
        private var observedMaximumRunningCount = 0
        private var observedQualityOfServiceClasses: Set<UInt32> = []
        private var observedSwiftConcurrencyThread = false

        var maximumRunningCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return observedMaximumRunningCount
        }

        var qualityOfServiceClasses: Set<UInt32> {
            lock.lock()
            defer { lock.unlock() }
            return observedQualityOfServiceClasses
        }

        var ranOnSwiftConcurrencyThread: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observedSwiftConcurrencyThread
        }

        func scanDidStart() {
            let qualityOfServiceClass = qos_class_self().rawValue
            // The pool's threads drain dispatch's `com.apple.root.…-qos.cooperative` queues.
            let isSwiftConcurrencyThread = String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
            lock.lock()
            defer { lock.unlock() }
            runningCount += 1
            observedMaximumRunningCount = max(observedMaximumRunningCount, runningCount)
            observedQualityOfServiceClasses.insert(qualityOfServiceClass)
            observedSwiftConcurrencyThread = observedSwiftConcurrencyThread || isSwiftConcurrencyThread
        }

        func scanDidEnd() {
            lock.lock()
            defer { lock.unlock() }
            runningCount -= 1
        }
    }

    @Test("Image scans run a few at a time, at utility priority, off the Swift concurrency threads")
    func scansRunAFewAtATimeOffTheThreadPool() async {
        let session = Self.makeSteadySession(maximumConcurrentScans: 3)
        let observer = ScanObserver()
        await withTaskGroup(of: Void.self) { group in
            for imageIndex in 0 ..< 9 {
                group.addTask {
                    _ = await session.sharedScan(of: .swiftType(CodeLocation(imageIndex: imageIndex, address: 0)), inImageAt: imageIndex, generation: 0) {
                        observer.scanDidStart()
                        Thread.sleep(forTimeInterval: 0.2)
                        observer.scanDidEnd()
                        return []
                    }
                }
            }
        }
        // At most three: on a busy machine dispatch may start fewer utility threads at once.
        #expect(observer.maximumRunningCount <= 3)
        #expect(observer.qualityOfServiceClasses == [QOS_CLASS_UTILITY.rawValue])
        #expect(!observer.ranOnSwiftConcurrencyThread)
    }

    @Test("A query's options set how many images the process scans at once; a query without leaves it")
    func optionsSetHowManyImagesAreScannedAtOnce() async throws {
        let session = Self.makeSteadySession(maximumConcurrentScans: 4)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        _ = try await query.callers(of: .selector("description"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions(resultLimit: 1, maximumConcurrentScans: 2)) { _ in }
        #expect(session.maximumConcurrentScans == 2)
        _ = try await query.callers(of: .selector("description"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions(resultLimit: 1)) { _ in }
        #expect(session.maximumConcurrentScans == 2)
    }

    @Test("A repeated query reuses the scan instead of scanning again")
    func scansAreReusedWithinTheSession() async throws {
        let session = Self.makeSteadySession()
        let query = Self.makeQuery(session: session)
        let firstRecorder = ProgressRecorder()
        let first = try await query.callers(of: .selector("orderWindow:relativeTo:"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) {
            firstRecorder.record($0)
        }
        #expect(session.keptScanByteCount > 0)
        // A report per image scanned: the scan covered more than one.
        #expect(firstRecorder.reports.count > 1)

        let recorder = ProgressRecorder()
        let second = try await query.callers(of: .selector("orderWindow:relativeTo:"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) {
            recorder.record($0)
        }
        #expect(second == first)
        // One report, for every image found among the earlier scans.
        #expect(recorder.reports.count == 1)
    }

    @Test("Two queries asking about the same thing at once scan each image once")
    func concurrentQueriesShareTheirScans() async throws {
        let session = Self.makeSteadySession()
        let query = Self.makeQuery(session: session)
        // The Find navigator and the Inspector asking about one type at once: both find nothing
        // kept yet, and both start on AppKit.
        async let first = query.callers(of: .selector("makeKeyAndOrderFront:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        async let second = query.callers(of: .selector("makeKeyAndOrderFront:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let (firstResult, secondResult) = try await (first, second)

        #expect(firstResult == secondResult)
        #expect(session.startedScanCount == 1)
    }

    @Test("A scan found larger than the budget is not recorded again, and pushes nothing out a second time")
    func oversizedScansAreNotRecordedAgain() async throws {
        // About 440 sends in about a hundred images, and a dozen in AppKit.
        let large = RuntimeCrossReferenceSubject.selector("makeKeyAndOrderFront:")
        let small = RuntimeCrossReferenceSubject.selector("_makeKeyRegardlessOfVisibility")
        // How much each scan takes, with room for both.
        let measuring = Self.makeSteadySession()
        _ = try await Self.makeQuery(session: measuring).callers(of: large, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let largeByteCount = measuring.keptScanByteCount
        _ = try await Self.makeQuery(session: measuring).callers(of: small, in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let smallByteCount = measuring.keptScanByteCount - largeByteCount
        try #require(smallByteCount > 0 && smallByteCount < largeByteCount / 2)

        // A budget the large scan passes partway through.
        let session = Self.makeSteadySession(scanByteBudget: largeByteCount / 2)
        let query = Self.makeQuery(session: session)
        _ = try await query.callers(of: large, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { _ in }
        // Nothing of it is left behind.
        #expect(session.keptScanByteCount == 0)

        _ = try await query.callers(of: small, in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        #expect(session.keptScanByteCount == smallByteCount)
        // Asked again, the large scan does not grow past the small one again.
        _ = try await query.callers(of: large, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { _ in }
        #expect(session.keptScanByteCount == smallByteCount)
    }

    @Test("A scan larger than the session's budget is not kept")
    func oversizedScansAreNotKept() async throws {
        let session = CrossReferenceSession(scanByteBudget: 1)
        _ = try await Self.makeQuery(session: session).callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        #expect(session.keptScanByteCount == 0)
    }

    // MARK: - Members

    private static func makeObjCEngine() async throws -> (RuntimeEngine, RuntimeObject) {
        let engine = RuntimeEngine(source: .local, engineID: "test-cross-reference-members")
        try await engine.connect()
        try await engine.loadImage(at: libobjcPath)
        let objects = try await engine.objects(in: libobjcPath)
        let rootClass = try #require(objects.first { $0.kind == .objc(.type(.class)) && $0.name == "NSObject" })
        return (engine, rootClass)
    }

    @Test("A member's callees carry the member on the function they come from")
    func calleesOfAMember() async throws {
        let (engine, rootClass) = try await Self.makeObjCEngine()
        let member = RuntimeMemberReference(object: rootClass, name: "respondsToSelector:", kind: .objcMethod, isStatic: false)
        let result = try await engine.callees(of: .member(member))
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { $0.referencingFunction.member == member })
    }

    @Test("A send to self from the method's own class is an exact caller of the member")
    func callersOfAMemberWeighTheReceiver() async throws {
        let (engine, rootClass) = try await Self.makeObjCEngine()
        let member = RuntimeMemberReference(object: rootClass, name: "description", kind: .objcMethod, isStatic: false)
        let result = try await engine.callers(of: .member(member), in: .image(path: Self.libobjcPath))
        // `-[NSObject debugDescription]` is `return [self description];` —
        // folded or not with its class twin, one of them sends to self.
        let fromDebugDescription = result.references.filter {
            ["-[NSObject debugDescription]", "+[NSObject debugDescription]"].contains($0.referencingFunction.displayName)
        }
        #expect(
            fromDebugDescription.contains { $0.precision == .exact },
            """
            from debugDescription: \(fromDebugDescription.map { "\($0.referencingFunction.displayName ?? "?") \($0.kind) \($0.precision) \($0.target)" })
            every caller: \(result.references.prefix(20).map { "\($0.referencingFunction.displayName ?? "0x" + String($0.referencingFunction.address, radix: 16)) \($0.precision)" })
            """
        )
    }

    @Test("A query on an engine reads the images that engine has indexed, and refuses one it has not")
    func queriesReadTheirEnginesIndexedImages() async throws {
        let (engine, _) = try await Self.makeObjCEngine()
        let indexedImagePaths = Set(try await engine.indexedImagePathList())
        try #require(indexedImagePaths.contains(Self.libobjcPath))
        try #require(!indexedImagePaths.contains(Self.foundationPath))

        // `-[NSObject debugDescription]` sends it, and so does nearly every image: the limit
        // stops a scan that reads them all at once rather than minutes later.
        let recorder = ProgressRecorder()
        let result = try await engine.callers(of: .selector("description"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions(resultLimit: 1000)) { recorder.record($0) }
        #expect(!result.references.isEmpty)
        #expect(result.references.allSatisfy { indexedImagePaths.contains($0.referencingFunction.imagePath) })
        #expect(recorder.reports.allSatisfy { $0.totalImageCount <= indexedImagePaths.count })

        await #expect(throws: RuntimeCrossReferenceError.imageNotIndexed(path: Self.foundationPath)) {
            try await engine.callers(of: .selector("description"), in: .image(path: Self.foundationPath))
        }
    }

    @Test("Storage has no code: an ivar is not a subject")
    func storageIsNotASubject() async throws {
        let (engine, rootClass) = try await Self.makeObjCEngine()
        let member = RuntimeMemberReference(object: rootClass, name: "isa", kind: .objcIvar, isStatic: false)
        await #expect(throws: RuntimeCrossReferenceError.memberNotFound(objectName: rootClass.displayName, memberName: "isa")) {
            try await engine.callees(of: .member(member))
        }
    }
}
#endif

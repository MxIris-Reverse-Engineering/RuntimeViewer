#if arch(arm64)
import Testing
import Foundation
import RuntimeViewerCore
import CrossReferenceAnalysis
@testable import RuntimeViewerCrossReferences

/// Queries against the dyld shared cache this process maps — the same code
/// the engine's process reads in the app. Expectations come from the cache
/// itself (a function's address is looked up, never written down), so an OS
/// update changes what is found, not whether the tests hold.
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

    private static func makeQuery(session: CrossReferenceSession = CrossReferenceSession()) -> CrossReferenceQuery {
        CrossReferenceQuery(engine: RuntimeEngine(source: .local, engineID: "test-cross-reference-queries"), session: session)
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
        // A send's receiver is either known — and then exact — or not.
        for reference in result.references {
            guard case .selector(_, let receiverClassName) = reference.target, reference.kind == .messageSend else { continue }
            #expect(reference.precision == (receiverClassName == nil ? .matchedBySelector : .exact))
        }

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

    // MARK: - Callers

    @Test("Callers of a selector in one image are exactly its sends, and the reports add up to the result")
    func callersOfASelectorInOneImage() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-cross-reference-callers")
        let recorder = ProgressRecorder()
        let result = try await engine.callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath)) { progress in
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

    @Test("Callers across all images are prefiltered: a selector few images send scans few images")
    func callersAcrossAllImagesArePrefiltered() async throws {
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery().callers(
            of: .selector("orderWindow:relativeTo:"),
            in: .allImages,
            options: RuntimeCrossReferenceQueryOptions(),
            reportProgress: { recorder.record($0) }
        )
        #expect(result.isComplete)
        let total = try #require(recorder.reports.last?.totalImageCount)
        #expect(total > 0)
        #expect(total < Self.analyzer.imagePaths.count / 10)
        #expect(result.references.contains { $0.referencingFunction.imagePath == Self.appKitPath })
    }

    @Test("A limit stops the scan with exactly that many references")
    func limitStopsTheScan() async throws {
        let recorder = ProgressRecorder()
        let result = try await Self.makeQuery().callers(
            of: .selector("init"),
            in: .allImages,
            options: RuntimeCrossReferenceQueryOptions(resultLimit: 100),
            reportProgress: { recorder.record($0) }
        )
        #expect(result.references.count == 100)
        #expect(!result.isComplete)
        #expect(recorder.reports.flatMap(\.references).count == 100)
        let last = try #require(recorder.reports.last)
        #expect(last.scannedImageCount < last.totalImageCount)
    }

    @Test("Cancelling the caller stops a whole-cache scan")
    func cancellationStopsTheScan() async throws {
        let query = Self.makeQuery()
        let recorder = ProgressRecorder()
        let (firstReport, firstReportContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await query.callers(of: .selector("init"), in: .allImages, options: RuntimeCrossReferenceQueryOptions()) { progress in
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

    // MARK: - Session

    @Test("A repeated query reuses the scan instead of scanning again")
    func scansAreReusedWithinTheSession() async throws {
        let session = CrossReferenceSession()
        let query = Self.makeQuery(session: session)
        let first = try await query.callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        #expect(session.keptScanByteCount > 0)

        let recorder = ProgressRecorder()
        let second = try await query.callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath), options: RuntimeCrossReferenceQueryOptions()) {
            recorder.record($0)
        }
        #expect(second == first)
        // One report, for the image found among the earlier scans.
        #expect(recorder.reports.count == 1)
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

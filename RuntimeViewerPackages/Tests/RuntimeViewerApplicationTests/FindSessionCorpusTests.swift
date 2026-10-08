import Foundation
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find session against corpora that keep arriving: a search on screen
/// reads an image built after it ran without starting over, and the summary
/// bar says what is still being made searchable.
@Suite("FindSession and the corpus", .serialized)
@MainActor
struct FindSessionCorpusTests {
    @Test("a search on screen reads an image whose corpus is built after it ran, keeping what it already found")
    func searchWidensToNewlyBuiltImage() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.widen", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

        let session = documentState.findSession
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

        var sawResultsCleared = false
        let disposeBag = DisposeBag()
        session.$results.asDriver()
            .driveOnNext { results in
                if results.nodes.isEmpty { sawResultsCleared = true }
            }
            .disposed(by: disposeBag)

        // Opening Foundation is what brings its corpus in after the search.
        try await engine.loadImage(at: TestImages.foundation)

        let widened = try await nextValue(from: session.$results.asDriver(), timeout: 180) { results in
            results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation }
        }
        #expect(widened.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
        #expect(!sawResultsCleared, "the results were emptied on the way instead of being merged into")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        #expect(session.summary?.contains("results in") == true)
        withExtendedLifetime(disposeBag) {}

        await engine.stop()
    }

    @Test("a corpus built after the search, outside its scope, is not read")
    func corpusOutsideScopeIsNotRead() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.outsideScope", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

        let session = documentState.findSession
        session.run(FindQuery(mode: .text, text: "NSObject", scope: .images([TestImages.libobjc])))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }

        // Opening Foundation brings its corpus in after the search. The
        // session hears of it one main-actor turn after the coordinator
        // reports it, so that turn has to pass before a search it would
        // start can be waited for.
        try await engine.loadImage(at: TestImages.foundation)
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 180) { $0[TestImages.foundation]?.isBuilt == true }
        try await settleMainQueue()
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })
        #expect(!session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.foundation })

        await engine.stop()
    }

    @Test("picking images asks the corpus coordinator for those not yet searchable")
    func pickingImagesAsksForTheirCorpora() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.pickedCorpora")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc] == nil)

        documentState.findSession.update { $0.scope = .images([TestImages.libobjc]) }

        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc] != nil)
        await engine.stop()
    }

    // MARK: - An iOS Simulator engine

    /// On an iOS Simulator engine a scope spells an image the way the sidebar
    /// does, without the simulator's root, while the corpus coordinator, the
    /// engine's summaries and the corpora it reports built spell it with it
    /// (PR121.33). The root here comes from the engine's test seam, which
    /// changes only how the client spells paths: the in-process engine keeps
    /// keying its own corpora without a root.
    private static let simulatorRoot = "/sim_root"

    private static func simulatorPath(of imagePath: String) -> String {
        simulatorRoot + imagePath
    }

    @Test("on a simulator engine, a corpus built later inside the scope is read, one already read is not")
    func simulatorCorpusBuiltLaterInsideTheScopeIsRead() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.simulatorWidening", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        engine.setDyldRootPathForTesting(Self.simulatorRoot)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true, scope: .images([TestImages.libobjc, TestImages.foundation])))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

        // The image the search already read, as the coordinator reports it.
        session.corpusDidBuild(at: Self.simulatorPath(of: TestImages.libobjc))
        #expect(!session.isSearching, "an image the search already read was read again")

        // An image of the scope the search could not read yet.
        session.corpusDidBuild(at: Self.simulatorPath(of: TestImages.foundation))
        #expect(session.isSearching, "a corpus built inside the scope was not read")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
        await engine.stop()
    }

    @Test("on a simulator engine, the summary bar counts the scope's images being made searchable")
    func simulatorSummaryCountsTheScopesImages() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.simulatorSummary", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        engine.setDyldRootPathForTesting(Self.simulatorRoot)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Off, so the coordinator asks for nothing and its states are the
        // ones this test merges in.
        environment.settings.search.isCorpusEnabled = false
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        // The coverage the coordinator fetches as it starts, then Foundation
        // being built, as a simulator engine reports it.
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 20) { $0[TestImages.libobjc]?.isBuilt == true }
        coordinator.mergeCoverage(RuntimeInterfaceCorpusCoverage(
            statesByImagePath: [Self.simulatorPath(of: TestImages.foundation): .building(RuntimeInterfaceCorpusBuildProgress(built: 1, total: 10))],
            residentByteCount: 0,
            residentByteLimit: 0
        ))

        let session = documentState.findSession
        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true, scope: .images([TestImages.libobjc, TestImages.foundation])))

        let summary = try await nextValue(from: session.$summary.asDriver(), timeout: 20) { $0?.contains("being made searchable") == true }
        #expect(summary?.contains("1 image being made searchable · building Foundation 10%") == true, "the summary bar says \(summary ?? "nothing")")
        await engine.stop()
    }

    @Test("on a simulator engine, picking an image already searchable asks for nothing")
    func simulatorPickingABuiltImageAsksForNothing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionCorpusTests.simulatorPick", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        engine.setDyldRootPathForTesting(Self.simulatorRoot)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime(coordinator) {} }
        // What the coordinator does as it starts — ask for the indexed images,
        // fetch the coverage — has to be over before the states are set here.
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 20) { states in
            states[TestImages.libobjc]?.isBuilt == true && !states.values.contains(where: \.isActive)
        }
        let canonicalPath = Self.simulatorPath(of: TestImages.libobjc)
        // libobjc built, as a simulator engine reports it.
        coordinator.mergeCoverage(RuntimeInterfaceCorpusCoverage(
            statesByImagePath: [canonicalPath: .built(RuntimeInterfaceCorpusBuildSummary(objectCount: 1, skippedCount: 0, byteCount: 1))],
            residentByteCount: 0,
            residentByteLimit: 0
        ))
        // The session hears of the states one main-actor turn later.
        try await settleMainQueue()

        documentState.findSession.update { $0.scope = .images([TestImages.libobjc]) }

        // A request for it would come back unindexed from this in-process
        // engine and take the built state with it.
        let states = try await values(from: coordinator.$buildStatesByImagePath.asDriver(), during: 1)
        #expect(states.allSatisfy { $0[canonicalPath]?.isBuilt == true }, "picking a built image asked for its corpus again")
        await engine.stop()
    }

    @Test("the summary bar speaks only of the corpora in the search's scope")
    func corpusStatusWithinScope() {
        let states: [String: RuntimeInterfaceCorpusBuildState] = [
            "/usr/lib/libobjc.A.dylib": .pending,
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation": .building(RuntimeInterfaceCorpusBuildProgress(built: 37, total: 100)),
        ]
        #expect(FindSession.corpusStatus(of: states, within: ["/usr/lib/libobjc.A.dylib"]) == "1 image being made searchable")
        #expect(FindSession.corpusStatus(of: states, within: ["/usr/lib/swift/libswiftCore.dylib"]) == nil)
    }

    @Test("the summary bar says how many images are being made searchable and which is printing")
    func corpusStatusText() {
        let states: [String: RuntimeInterfaceCorpusBuildState] = [
            "/usr/lib/libobjc.A.dylib": .pending,
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation": .building(RuntimeInterfaceCorpusBuildProgress(built: 37, total: 100)),
            "/usr/lib/swift/libswiftCore.dylib": .built(RuntimeInterfaceCorpusBuildSummary(objectCount: 1, skippedCount: 0, byteCount: 1)),
        ]
        #expect(FindSession.corpusStatus(of: states) == "2 images being made searchable · building Foundation 37%")
        #expect(FindSession.corpusStatus(of: ["/usr/lib/libobjc.A.dylib": .failed(message: "boom")]) == nil)
    }

    private static func imagePath(of node: FindResultNode) -> String? {
        if case .object(let object, _) = node.content {
            return object.imagePath
        }
        return nil
    }
}

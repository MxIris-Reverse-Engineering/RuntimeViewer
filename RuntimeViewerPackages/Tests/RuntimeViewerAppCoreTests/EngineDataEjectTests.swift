#if canImport(Network)

import Foundation
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerSettings

/// The Report navigator's Searchable Interfaces and Cross References rows show what the engine's
/// process keeps for them, and eject it, as Finder ejects a volume: the Find corpora, or the
/// prepared cross references, are dropped from the engine's process and come back only when
/// something needs them — a corpus its derived data holds stays searchable, read back by the next
/// search (proposal `on-demand-corpora-and-cross-references`). Nothing drops them on its own —
/// closing the last window on an engine did, and reopening one then rebuilt everything (proposal
/// `engine-resident-memory`).
@Suite("Ejecting an engine's corpora and cross references", .serialized)
@MainActor
struct EngineDataEjectTests {
    /// What the scripted engine keeps of prepared cross references until they are ejected: a size
    /// the row prints without a fraction.
    private nonisolated static let preparedByteCount = 214 * 1024 * 1024

    /// The limit the test settings keep prepared cross references within: the default.
    private nonisolated static let preparedByteLimit = Settings.Search.default.crossReferenceResidentByteLimit

    @Test("ejecting Searchable Interfaces drops the corpora of an engine without derived data, which stay unbuilt until something asks")
    func ejectingSearchableInterfacesDropsTheCorpora() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "EngineDataEjectTests.corpora", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
        environment.startBackgroundWork()
        let page = environment.make { EjectingReportPage(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let categoryNode = try await page.node(.category(.searchableInterfaces), within: 60) { $0.cellViewModel.appearance.showsEjectButton }

        page.ejectRelay.accept(categoryNode)

        try await Self.poll { (try? await engine.interfaceCorpusCoverage())?.residentByteCount == 0 }
        // Long enough for libobjc's corpus to be read or printed again, had anything asked.
        try await Task.sleep(for: .seconds(1))
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt != true, "the corpus came back without anything asking for it")
        try await waitUntil { page.node(.category(.searchableInterfaces))?.cellViewModel.appearance.showsEjectButton != true }
        await engine.stop()
    }

    @Test("ejecting Searchable Interfaces frees the memory of a corpus derived data holds, which stays built and is read back by a search")
    func ejectingKeepsStoredCorporaSearchable() async throws {
        let fixture = try DerivedDataFixture()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "EngineDataEjectTests.storedCorpora", loading: [TestImages.libobjc])
        await engine.useDerivedDataStore(fixture.store)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
        environment.startBackgroundWork()
        let page = environment.make { EjectingReportPage(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let categoryNode = try await page.node(.category(.searchableInterfaces), within: 60) { $0.cellViewModel.appearance.showsEjectButton }

        page.ejectRelay.accept(categoryNode)

        try await Self.poll { (try? await engine.interfaceCorpusCoverage())?.residentByteCount == 0 }
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt == true, "derived data holds it")
        var matches: [RuntimeInterfaceSearchMatch] = []
        _ = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(text: "NSObject", matchMode: .matchingWord, isCaseSensitive: true)) { matches += $0 }
        #expect(!matches.isEmpty, "read back for the search")
        await engine.stop()
    }

    @Test("ejecting Cross References drops the engine's prepared images and puts its limit back")
    func ejectingCrossReferencesDropsThePreparedImages() async throws {
        let peer = try await ScriptedPeer.make(label: "EngineDataEjectTests.crossReferences")
        defer { Task { await peer.stop() } }
        let preparedCrossReferences = ScriptedPreparedCrossReferences(byteCount: Self.preparedByteCount)
        peer.serve(.interfaceCorpusCoverage) { RuntimeInterfaceCorpusCoverage.empty }
        peer.serve(.indexedImagePaths) { [String]() }
        peer.serve(.crossReferenceSetPreparedByteLimit, reading: ByteLimitRequest.self) { request in
            await preparedCrossReferences.setLimit(request.byteLimit)
            return RuntimeEngineEmpty()
        }
        peer.serve(.crossReferencePreparedByteCount) { await preparedCrossReferences.byteCount }
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCrossReferencePreparationEnabled = true
        environment.startBackgroundWork()
        let page = environment.make { EjectingReportPage(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let categoryNode = try await page.node(.category(.crossReferences)) { $0.cellViewModel.appearance.showsEjectButton }
        #expect(categoryNode.cellViewModel.appearance.detail == "214 MB")

        page.ejectRelay.accept(categoryNode)

        try await Self.poll { await preparedCrossReferences.limits.suffix(2) == [0, Self.preparedByteLimit] }
        try await waitUntil { page.node(.category(.crossReferences))?.cellViewModel.appearance.showsEjectButton != true }
        #expect(await preparedCrossReferences.limits.last == Self.preparedByteLimit, "the limit stayed at zero: nothing a query prepares from now on would be kept")
    }

    // MARK: - Support

    private static func poll(timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { throw AwaitTimeout(seconds: timeout) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The field of the byte-limit command.
    private struct ByteLimitRequest: Codable {
        let byteLimit: Int
    }
}

/// An engine's prepared cross references as the scripted peer keeps them: a size, which a zero
/// limit drops, and every limit it was given, in order.
private actor ScriptedPreparedCrossReferences {
    private(set) var byteCount: Int

    private(set) var limits: [Int] = []

    init(byteCount: Int) {
        self.byteCount = byteCount
    }

    func setLimit(_ byteLimit: Int) {
        limits.append(byteLimit)
        if byteLimit == 0 {
            byteCount = 0
        }
    }
}

/// The Report navigator page, its Eject wired to a relay the test fires.
@MainActor
private final class EjectingReportPage {
    /// Held here because the ViewModel keeps its router `unowned`.
    let router = MockRouter<SidebarRootRoute>()
    let ejectRelay = PublishRelay<ReportNode>()
    let viewModel: ReportViewModel<SidebarRootRoute>
    private(set) var nodes: [ReportNode] = []
    private let disposeBag = DisposeBag()

    init(documentState: DocumentState) {
        viewModel = ReportViewModel(documentState: documentState, router: router)
        let output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
            isVisible: .just(true),
            cancel: .empty(),
            cancelAll: .empty(),
            clearHistory: .empty(),
            openSettings: .empty(),
            doubleClickedNode: .empty(),
            filter: .just(.empty),
            showsOnlyInProgress: .just(false),
            eject: ejectRelay.asSignal()
        ))
        output.nodes.driveOnNext { [weak self] nodes in
            guard let self else { return }
            self.nodes = nodes
        }
        .disposed(by: disposeBag)
    }

    func node(_ identifier: ReportNodeIdentifier) -> ReportNode? {
        nodes.first { $0.identifier == identifier }
    }

    /// The row `identifier` names once `condition` holds of it.
    func node(_ identifier: ReportNodeIdentifier, within timeout: TimeInterval = 10, where condition: (ReportNode) -> Bool) async throws -> ReportNode {
        try await waitUntil(timeout: timeout) { node(identifier).map(condition) == true }
        return try #require(node(identifier))
    }
}

#endif

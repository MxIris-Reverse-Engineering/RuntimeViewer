import AppKit
import Dependencies
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerSettings

/// The Report of a document that borrows shared cache images lists each engine's work in a group
/// of its own — the document's engine first, then every engine it borrows from — with the three
/// kinds of work inside, and what is done on a group's rows reaches that group's work. A document
/// that borrows nothing shows the kinds of work at the top, as it always did.
@Suite("Report groups by engine", .serialized)
@MainActor
struct ReportEngineGroupsTests {
    /// Small, never indexed by a fresh engine, and quick to index for real.
    private static let smallImage = "/usr/lib/libSystem.B.dylib"

    private static func isCategory(_ node: ReportNode) -> Bool {
        if case .category = node.identifier { return true }
        return false
    }

    @Test("a document that borrows nothing shows the kinds of work at the top")
    func withoutBorrowingTheKindsAreAtTheTop() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.alone", isBorrowing: false)
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let page = environment.make { ReportGroupsPage(documentState: environment.documentState) }

        let nodes = try await nextValue(from: page.nodes) { !$0.isEmpty }

        #expect(nodes.allSatisfy(Self.isCategory), "a document that borrows nothing shows rows above its kinds of work: \(nodes.map(\.identifier))")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("a document that borrows lists its engine's work and its owner's in groups of their own, no two rows alike")
    func borrowingListsAGroupPerEngine() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.groups")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let page = environment.make { ReportGroupsPage(documentState: environment.documentState) }
        let owner = ObjectIdentifier(fixture.ownerEngine)

        let nodes = try await nextValue(from: page.nodes) { $0.count == 2 }

        #expect(nodes.map(\.identifier) == [.engineGroup(.own), .engineGroup(.owner(owner))])
        #expect(nodes.map(\.cellViewModel.appearance.title) == [fixture.borrowerEngine.source.description, fixture.ownerEngine.source.description])
        #expect(!nodes[0].children.isEmpty && nodes[0].children.allSatisfy(Self.isCategory))
        // The two engines' work is configured alike, so the owner's group lists the same kinds.
        #expect(nodes[1].children.map(\.identifier) == nodes[0].children.map { .borrowed(owner: owner, identifier: $0.identifier) })
        let identifiers = Self.identifiers(in: nodes)
        #expect(Set(identifiers).count == identifiers.count, "two rows of the Report share an identifier")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("a group's row shows its engine's icon, and keeps the same image while the Report is built again")
    func groupRowsShowTheirEnginesIcons() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.icons")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let page = environment.make { ReportGroupsPage(documentState: environment.documentState) }
        let owner = ObjectIdentifier(fixture.ownerEngine)

        let nodes = try await nextValue(from: page.nodes) { $0.count == 2 }

        let rowIcons = try nodes.map { try #require($0.cellViewModel.appearance.icon) }
        @Dependency(\.runtimeEngineIconProvider) var runtimeEngineIconProvider
        let engineIcons = [fixture.borrowerEngine, fixture.ownerEngine].map { runtimeEngineIconProvider.icon(for: $0) }
        let rowPixels = try rowIcons.map(Self.pixels)
        let enginePixels = try engineIcons.map(Self.pixels)
        #expect(rowPixels == enginePixels, "a group's row does not show its engine's icon")

        // Every step of a batch on the owner's work builds the rows again.
        _ = await fixture.ownerEngine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual)
        let rebuiltNodes = try await nextValue(from: page.nodes, timeout: 60) { nodes in
            nodes.count == 2 && Self.identifiers(in: nodes[1].children).contains { identifier in
                if case .borrowed(owner, .indexingBatch) = identifier { return true }
                return false
            }
        }

        let keepsItsImage = zip(rebuiltNodes, rowIcons).allSatisfy { node, rowIcon in node.cellViewModel.appearance.icon === rowIcon }
        #expect(keepsItsImage, "a group's row took a new image when the Report was built again")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("a borrowing document whose engines have nothing to report shows an empty Report, not empty groups")
    func nothingToReportIsEmpty() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.empty")
        let environment = ViewModelTestEnvironment(runtimeEngine: fixture.borrowerEngine)
        // Every kind on and idle: no batch to start, no corpus to build on two fresh engines.
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
        environment.startBackgroundWork()
        let page = environment.make { ReportGroupsPage(documentState: environment.documentState) }

        let shownNodes = try await values(from: page.nodes, during: 0.5)

        let isEmptyThroughout = shownNodes.allSatisfy { $0.isEmpty }
        #expect(!shownNodes.isEmpty)
        #expect(isEmptyThroughout, "the Report showed \(shownNodes.last.map { $0.map(\.identifier) } ?? [])")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("a row of an owner's group stands for the owner's work, any other for the engine's own")
    func rowsStandForTheirGroupsWork() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.targets")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let session = environment.documentState.runtimeEngineSession
        let ownWork = try #require(session.backgroundWork)
        let ownerWork = try #require(session.borrowedBackgroundWorks.first)
        let batchIdentifier = RuntimeIndexingBatchID()

        let ownTarget = try #require(ReportGroupWork.target(of: .indexingBatch(batchIdentifier), in: session))
        let ownerTarget = try #require(ReportGroupWork.target(of: .borrowed(owner: ObjectIdentifier(fixture.ownerEngine), identifier: .indexingBatch(batchIdentifier)), in: session))

        #expect(ownTarget.backgroundWork === ownWork)
        #expect(ownTarget.identifier == .indexingBatch(batchIdentifier))
        #expect(ownerTarget.backgroundWork === ownerWork)
        #expect(ownerTarget.identifier == .indexingBatch(batchIdentifier))
        let unknownOwner = ObjectIdentifier(environment.documentState)
        #expect(ReportGroupWork.target(of: .borrowed(owner: unknownOwner, identifier: .indexingBatch(batchIdentifier)), in: session) == nil, "a row of an engine the document does not borrow from found work")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("Clear History clears the history of every engine the Report lists")
    func clearHistoryReachesTheOwner() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "report.clear")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let ownerWork = try #require(environment.documentState.runtimeEngineSession.borrowedBackgroundWorks.first)
        let page = environment.make { ReportGroupsPage(documentState: environment.documentState) }
        _ = try await nextValue(from: page.nodes) { $0.count == 2 }
        _ = await fixture.ownerEngine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual)
        _ = try await nextValue(from: ownerWork.indexingCoordinator.historyObservable, timeout: 60) { !$0.isEmpty }

        page.clearHistoryRelay.accept(())

        let history = try await nextValue(from: ownerWork.indexingCoordinator.historyObservable)
        #expect(history.isEmpty, "the owner's history outlived Clear History in a borrowing window")
        environment.make { environment.documentState.documentWillClose() }
        await fixture.stop()
    }

    @Test("the activity of several engines reads as one: every run under way, the newest first, and the run that ended last")
    func activitySnapshotsMerge() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let olderRun = ActivityReport(kind: .backgroundIndexing, startDate: start)
        let newerRun = ActivityReport(kind: .searchableInterfaces, startDate: start.addingTimeInterval(10))
        let earlierEnd = ActivityReport(kind: .crossReferences, startDate: start, completion: .init(outcome: .succeeded, date: start.addingTimeInterval(5)))
        let laterEnd = ActivityReport(kind: .backgroundIndexing, startDate: start, completion: .init(outcome: .failed, date: start.addingTimeInterval(20)))

        let merged = ActivityReportsSnapshot.merged([
            ActivityReportsSnapshot(runningReports: [olderRun], lastCompletedReport: laterEnd),
            ActivityReportsSnapshot(runningReports: [newerRun], lastCompletedReport: earlierEnd),
        ])

        #expect(merged.runningReports == [newerRun, olderRun])
        #expect(merged.lastCompletedReport == laterEnd)
    }

    // MARK: - Support

    private static func environment(on engine: RuntimeEngine) -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        return environment
    }

    private static func identifiers(in nodes: [ReportNode]) -> [ReportNodeIdentifier] {
        nodes.flatMap { [$0.identifier] + identifiers(in: $0.children) }
    }

    /// The pixels of `image` drawn as a row's 16-point icon on a 2× screen, in the light
    /// appearance: what two images show, to compare.
    private static func pixels(of image: NSImage) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 16, height: 16)
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        lightAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        }
        NSGraphicsContext.restoreGraphicsState()
        let bitmapData = try #require(bitmap.bitmapData)
        return Data(bytes: bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}

/// A Report page on screen, its outline as a stream.
@MainActor
private final class ReportGroupsPage {
    /// Held here because the ViewModel keeps its router `unowned`.
    let router = MockRouter<SidebarRootRoute>()
    let clearHistoryRelay = PublishRelay<Void>()
    let viewModel: ReportViewModel<SidebarRootRoute>
    let nodes: Driver<[ReportNode]>

    init(documentState: DocumentState) {
        viewModel = ReportViewModel(documentState: documentState, router: router)
        let output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
            isVisible: .just(true),
            cancel: .empty(),
            cancelAll: .empty(),
            clearHistory: clearHistoryRelay.asSignal(),
            openSettings: .empty(),
            doubleClickedNode: .empty(),
            filter: .just(.empty),
            showsOnlyInProgress: .just(false)
        ))
        nodes = output.nodes
    }
}

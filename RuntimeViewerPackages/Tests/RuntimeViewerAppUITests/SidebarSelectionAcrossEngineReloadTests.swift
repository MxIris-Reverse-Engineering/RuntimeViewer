import AppKit
import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerAppCore

/// The runtime-object sidebar keeps the row the user selected while background indexing goes on.
///
/// Every batch of background indexing ends with the engine reloading its data
/// (`reloadDataAfterBackgroundIndexing()`, `reloadData(isReloadImageNodes: false)`), and every
/// object list on the engine reloads in turn. The list used to make a new cell ViewModel for every
/// row on each reload and hand the outline the new rows, which `NSOutlineView` cannot match to the
/// old ones: the selection vanished a moment after the user picked a row, again after every
/// batch, until indexing was over.
///
/// The fixture binds a real `SidebarRuntimeObjectListViewModel`, on a private engine, to a
/// `StatefulOutlineView` the way `SidebarRuntimeObjectViewController` and its list subclass bind
/// theirs: RxAppKit's sections adapter over the kind sections, the list's `selectCell` put back
/// into the outline, and the selection kept on its item across reloads. The objects are seeded, so
/// a test decides what the reload lists. It has no window: the selection and the reload are the
/// outline's data, and a window would put the test on screen.
@Suite("SidebarSelectionAcrossEngineReload", .serialized)
@MainActor
struct SidebarSelectionAcrossEngineReloadTests {
    @Test("a reload after a background indexing batch leaves the selection on the object the user selected")
    func selectionSurvivesTheReloadAfterABackgroundIndexingBatch() async throws {
        let fixture = try await Fixture.make(listing: ["SeededClassB", "SeededClassM", "SeededClassZ"])
        defer { fixture.tearDown() }
        let selectedObject = try await fixture.clickLoadedRow(named: "SeededClassM")

        try await fixture.reloadAsABackgroundIndexingBatchEnds()

        let selectedCellAfterReload = fixture.selectedCell()
        #expect(
            selectedCellAfterReload?.runtimeObject == selectedObject,
            "selected after the reload: \(selectedCellAfterReload?.runtimeObject.displayName ?? "no row") (row \(fixture.outlineView.selectedRow))"
        )
    }

    @Test("a reload that lists a new object above the selected one leaves the selection on the object the user selected")
    func selectionSurvivesAReloadThatAddsARowAboveIt() async throws {
        let fixture = try await Fixture.make(listing: ["SeededClassB", "SeededClassM", "SeededClassZ"])
        defer { fixture.tearDown() }
        let selectedObject = try await fixture.clickLoadedRow(named: "SeededClassM")

        fixture.list(["SeededClassA", "SeededClassB", "SeededClassM", "SeededClassZ"])
        try await fixture.reloadAsABackgroundIndexingBatchEnds()

        try #require(fixture.rowCount(ofObjects: SidebarSelectionAcrossEngineReloadTests.seededKind) == 4, "the reload did not reach the outline")
        let selectedCellAfterReload = fixture.selectedCell()
        #expect(
            selectedCellAfterReload?.runtimeObject == selectedObject,
            "selected after the reload: \(selectedCellAfterReload?.runtimeObject.displayName ?? "no row") (row \(fixture.outlineView.selectedRow))"
        )
    }

    fileprivate static let seededKind: RuntimeObjectKind = .objc(.type(.class))
}

// MARK: - Fixture

extension SidebarSelectionAcrossEngineReloadTests {
    @MainActor
    final class Fixture {
        let engine: RuntimeEngine
        let scrollView: NSScrollView
        let outlineView: StatefulOutlineView

        private let environment: ViewModelTestEnvironment
        private let imageTree: RuntimeImageNode
        private let router = MockRouter<SidebarRuntimeObjectRoute>()
        private let viewModel: SeededListViewModel
        private let runtimeObjectClickedRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()
        private let disposeBag = DisposeBag()

        static func make(listing objectNames: [String]) async throws -> Fixture {
            // A private engine: the reload this suite sets off reaches every object list on its
            // engine, and the shared one's are other suites'.
            let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: "SidebarSelectionAcrossEngineReloadTests")
            return try Fixture(engine: engine, runtimeObjects: objectNames.map(Self.seededRuntimeObject(named:)))
        }

        private init(engine: RuntimeEngine, runtimeObjects: [RuntimeObject]) throws {
            self.engine = engine
            environment = ViewModelTestEnvironment(runtimeEngine: engine)
            // libobjc is mapped into every test process, so the engine reports it loaded and the
            // list goes on to the seeded objects.
            imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
            let imageNode = try #require(imageTree.leaf(forImagePath: TestImages.libobjc))
            viewModel = environment.make { [environment, router] in
                SeededListViewModel(seededRuntimeObjects: runtimeObjects, imageNode: imageNode, documentState: environment.documentState, router: router)
            }

            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.scrollView = scrollView
            self.outlineView = outlineView
            outlineView.style = .sourceList
            // As `SidebarRuntimeObjectViewController` sets it.
            outlineView.preservesSelectedItemAcrossReloads = true
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 680)

            let baseOutput = viewModel.transform(
                SidebarRuntimeObjectViewModel.Input(
                    runtimeObjectClicked: runtimeObjectClickedRelay.asSignal(),
                    runtimeObjectOpenedInNewTab: .empty(),
                    loadImageClicked: .empty(),
                    filter: .just(.empty),
                    isSearchCaseSensitive: .just(false)
                )
            )
            let listOutput = viewModel.transform(SidebarRuntimeObjectListViewModel.Input(addBookmark: .empty()))

            let sectionHeaderProvider: Reactive<NSOutlineView>.OutlineSectionHeaderViewProvider<SidebarRuntimeObjectSection> = { _, _, section in
                NSTextField(labelWithString: section.title)
            }
            let cellProvider: Reactive<NSOutlineView>.OutlineCellViewProvider<SidebarRuntimeObjectCellViewModel> = { _, _, cellViewModel in
                NSTextField(labelWithString: cellViewModel.runtimeObject.displayName)
            }
            let sectionsSource = baseOutput.runtimeObjectSections
                .asObservable()
                .map { $0.map { ArraySection(model: $0, elements: $0.objects) } }
            outlineView.rx.sections(source: sectionsSource)(sectionHeaderProvider, cellProvider, nil).disposed(by: disposeBag)

            // What `SidebarRuntimeObjectListViewController` does with the list's `selectCell`.
            listOutput.selectCell.emitOnNext { [outlineView] result in
                for ancestor in result.ancestors where !outlineView.isItemExpanded(ancestor) {
                    outlineView.expandItem(ancestor)
                }
                outlineView.selectRowBringingIntoView(outlineView.row(forItem: result.cell))
            }
            .disposed(by: disposeBag)
        }

        func tearDown() {
            withExtendedLifetime(viewModel) {}
        }

        /// What the next load of the list's objects finds.
        func list(_ objectNames: [String]) {
            viewModel.seededRuntimeObjects = objectNames.map(Self.seededRuntimeObject(named:))
        }

        /// Waits for the list to show the object, then clicks its row: AppKit selects the row, and
        /// the view controller reports the click to the list, which opens the object.
        func clickLoadedRow(named name: String) async throws -> RuntimeObject {
            var loadedCell: SidebarRuntimeObjectCellViewModel?
            _ = try await pollUntil(timeout: .seconds(60)) {
                loadedCell = cellInOutline(named: name)
                return loadedCell != nil
            }
            let cell = try #require(loadedCell, "the list never showed \(name)")
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: cell)), byExtendingSelection: false)
            runtimeObjectClickedRelay.accept(cell)
            try await settleMainQueue()
            try #require(selectedCell()?.runtimeObject == cell.runtimeObject, "the click did not leave \(name) selected")
            return cell.runtimeObject
        }

        func selectedCell() -> SidebarRuntimeObjectCellViewModel? {
            guard outlineView.selectedRow >= 0 else { return nil }
            return outlineView.item(atRow: outlineView.selectedRow) as? SidebarRuntimeObjectCellViewModel
        }

        func rowCount(ofObjects kind: RuntimeObjectKind) -> Int {
            (0 ..< outlineView.numberOfRows).count { row in
                (outlineView.item(atRow: row) as? SidebarRuntimeObjectCellViewModel)?.runtimeObject.kind == kind
            }
        }

        /// What the end of a background indexing batch does to the engine, and through it to the
        /// list: the engine reloads its data, and the list reloads its objects.
        func reloadAsABackgroundIndexingBatchEnds() async throws {
            let loadsBefore = viewModel.startedLoadCount
            await engine.reloadData(isReloadImageNodes: false)
            let reloaded = try await pollUntil(timeout: .seconds(60)) {
                viewModel.startedLoadCount > loadsBefore
            }
            try #require(reloaded, "the list never reloaded after the engine did")
            // The reload publishes what it loaded on the main actor once its objects arrive.
            try await settleMainQueue()
            try await settleMainQueue()
        }

        private func cellInOutline(named name: String) -> SidebarRuntimeObjectCellViewModel? {
            for row in 0 ..< outlineView.numberOfRows {
                guard let cell = outlineView.item(atRow: row) as? SidebarRuntimeObjectCellViewModel else { continue }
                if cell.runtimeObject.name == name {
                    return cell
                }
            }
            return nil
        }

        private static func seededRuntimeObject(named name: String) -> RuntimeObject {
            Fixtures.runtimeObject(name: name, kind: SidebarSelectionAcrossEngineReloadTests.seededKind, imagePath: TestImages.libobjc)
        }
    }
}

/// The object list over objects a test hands it, counting the loads it has started, so a test can
/// wait out a reload whether or not the reload changes what the list shows.
private final class SeededListViewModel: SidebarRuntimeObjectListViewModel {
    var seededRuntimeObjects: [RuntimeObject]
    private(set) var startedLoadCount = 0

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        startedLoadCount += 1
        return AsyncThrowingStream { [seededRuntimeObjects] continuation in
            continuation.yield(.completed(seededRuntimeObjects))
            continuation.finish()
        }
    }
}

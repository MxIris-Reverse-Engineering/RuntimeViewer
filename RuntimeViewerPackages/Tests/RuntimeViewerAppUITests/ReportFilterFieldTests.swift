import AppKit
import AppKitPlus
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerSettings

/// The Report navigator page fed by its own filter field, read the way the page reads it: RxCocoa's
/// `rx.stringValue` on AppKitPlus's `NSFilterSearchField`. The rest of the page is
/// `ReportViewModelTests`'.
@Suite("ReportViewModel filter field")
@MainActor
struct ReportFilterFieldTests {
    @Test("the outline shows its rows before the filter bar is touched")
    func outlineShowsBeforeFilterBarIsTouched() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportFilterFieldTests.untouchedFilterBar")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Both turned off, so the outline has its rows at once, with nothing to index or build.
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
        // The field's `rx.stringValue` reports only what is typed into it, so an untouched field
        // says nothing at all — nor does a clock toggle nobody has clicked.
        let filterSearchField = NSFilterSearchField()
        environment.startBackgroundWork()
        // Held here because the ViewModel keeps its router `unowned`.
        let router = MockRouter<SidebarRootRoute>()
        let (viewModel, output) = environment.make { () -> (ReportViewModel<SidebarRootRoute>, ReportViewModel<SidebarRootRoute>.Output) in
            let viewModel = ReportViewModel(documentState: environment.documentState, router: router)
            let output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
                isVisible: .just(true),
                cancel: .empty(),
                cancelAll: .empty(),
                clearHistory: .empty(),
                openSettings: .empty(),
                doubleClickedNode: .empty(),
                filter: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: "").map { NavigatorTextFilter(typedText: $0) },
                showsOnlyInProgress: .never()
            ))
            return (viewModel, output)
        }
        defer { withExtendedLifetime((viewModel, router)) {} }

        let nodes = try await nextValue(from: output.nodes) { !$0.isEmpty }

        #expect(nodes.map(\.identifier) == [.category(.backgroundIndexing), .category(.searchableInterfaces)])
        await engine.stop()
    }
}

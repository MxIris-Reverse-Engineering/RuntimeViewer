#if os(macOS)

import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Show in Finder on the two export sheets' last step goes through the Finder client, so a test
/// sees what would be revealed and no Finder window opens.
@Suite("Export completion reveals the destination")
@MainActor
struct ExportingCompletionViewModelTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<ExportingRoute>()
    private let showInFinderRelay = PublishRelay<Void>()

    private let destinationURL = URL(fileURLWithPath: "/tmp/RuntimeViewerExportDestination", isDirectory: true)

    @Test("Show in Finder reveals the single-image export's destination through the Finder client")
    func exportingCompletionRevealsDestinationThroughFinderClient() {
        let exportingState = ExportingState(imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A.dylib")
        exportingState.destinationURL = destinationURL
        let viewModel = environment.make {
            ExportingCompletionViewModel(exportingState: exportingState, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(refresh: .empty(), showInFinderClick: showInFinderRelay.asSignal()))

        showInFinderRelay.accept(())

        #expect(environment.finder.revealedFileURLs == [destinationURL])
    }

    @Test("Show in Finder reveals nothing while the single-image export has no destination")
    func exportingCompletionRevealsNothingWithoutDestination() {
        let exportingState = ExportingState(imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A.dylib")
        let viewModel = environment.make {
            ExportingCompletionViewModel(exportingState: exportingState, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(refresh: .empty(), showInFinderClick: showInFinderRelay.asSignal()))

        showInFinderRelay.accept(())

        #expect(environment.finder.revealedFileURLs.isEmpty)
    }

    @Test("Show in Finder reveals the batch export's destination through the Finder client")
    func batchExportingCompletionRevealsDestinationThroughFinderClient() {
        let exportingState = BatchExportingState()
        exportingState.destinationURL = destinationURL
        let viewModel = environment.make {
            BatchExportingCompletionViewModel(exportingState: exportingState, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(refresh: .empty(), showInFinderClick: showInFinderRelay.asSignal()))

        showInFinderRelay.accept(())

        #expect(environment.finder.revealedFileURLs == [destinationURL])
    }
}

#endif

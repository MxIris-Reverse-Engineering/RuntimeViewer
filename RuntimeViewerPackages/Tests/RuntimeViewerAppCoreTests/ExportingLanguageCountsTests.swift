#if os(macOS)

import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The two export sheets' last step counts the interfaces of each language,
/// C++ included (proposal `cplusplus-export`).
@Suite("Export completion counts each language")
@MainActor
struct ExportingLanguageCountsTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<ExportingRoute>()

    private static func result(objcCount: Int, swiftCount: Int, cPlusPlusCount: Int) -> RuntimeInterfaceExportResult {
        RuntimeInterfaceExportResult(
            succeeded: objcCount + swiftCount + cPlusPlusCount,
            failed: 0,
            totalDuration: 1,
            objcCount: objcCount,
            swiftCount: swiftCount,
            cPlusPlusCount: cPlusPlusCount
        )
    }

    private static func outcome(_ name: String, _ result: RuntimeInterfaceExportResult) -> BatchExportingPerImageOutcome {
        BatchExportingPerImageOutcome(
            image: BatchExportingImage(path: "/usr/lib/\(name)", name: name),
            outcome: .success(result)
        )
    }

    private func singleImageSummary(for result: RuntimeInterfaceExportResult) -> String {
        let exportingState = ExportingState(imagePath: "/usr/lib/libc++abi.dylib", imageName: "libc++abi.dylib")
        exportingState.exportResult = result
        let viewModel = environment.make {
            ExportingCompletionViewModel(exportingState: exportingState, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(refresh: .empty(), showInFinderClick: .empty()))
        return viewModel.summaryText
    }

    @Test func completionSummaryListsCPlusPlusCount() {
        let summary = singleImageSummary(for: Self.result(objcCount: 12, swiftCount: 3, cPlusPlusCount: 41))

        #expect(summary.contains("ObjC: 12 | Swift: 3 | C++: 41"))
    }

    @Test func completionSummaryOmitsCPlusPlusWhenThereIsNone() {
        let summary = singleImageSummary(for: Self.result(objcCount: 12, swiftCount: 3, cPlusPlusCount: 0))

        #expect(summary.contains("ObjC: 12 | Swift: 3"))
        #expect(!summary.contains("C++"))
    }

    @Test func batchSummaryShowsThreeLanguageCounts() {
        let exportingState = BatchExportingState()
        exportingState.aggregatedResult = BatchExportingAggregatedResult(outcomes: [
            Self.outcome("libc++abi.dylib", Self.result(objcCount: 12, swiftCount: 3, cPlusPlusCount: 41)),
        ])
        let viewModel = environment.make {
            BatchExportingCompletionViewModel(exportingState: exportingState, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(refresh: .empty(), showInFinderClick: .empty()))

        #expect(viewModel.summary.languageCountsValue == "12 · 3 · 41")
    }

    @Test func aggregatedResultAddsUpCPlusPlusCounts() {
        let aggregated = BatchExportingAggregatedResult(outcomes: [
            Self.outcome("libc++abi.dylib", Self.result(objcCount: 0, swiftCount: 0, cPlusPlusCount: 41)),
            Self.outcome("libc++.1.dylib", Self.result(objcCount: 0, swiftCount: 0, cPlusPlusCount: 9)),
            BatchExportingPerImageOutcome(
                image: BatchExportingImage(path: "/usr/lib/libMissing.dylib", name: "libMissing.dylib"),
                outcome: .failure(errorDescription: "not found")
            ),
        ])

        #expect(aggregated.totalCPlusPlusCount == 50)
        #expect(aggregated.imagesFailed == 1)
    }
}

#endif

import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingCompletionViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let refresh: Signal<Void>
        let showInFinderClick: Signal<Void>
    }

    struct Output {
        let summaryText: Driver<String>
        let rows: Driver<[BatchExportingCompletionRowViewModel]>
    }

    @Observed private(set) var summaryText: String = ""

    private let exportingState: BatchExportingState

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        exportingState.$aggregatedResult
            .asObservable()
            .compactMap { $0 }
            .subscribeOnNext { [weak self] result in
                guard let self else { return }
                summaryText = Self.makeSummary(from: result)
            }
            .disposed(by: rx.disposeBag)

        input.refresh.emitOnNext { [weak self] in
            guard let self else { return }
            refreshFromState()
        }
        .disposed(by: rx.disposeBag)

        input.showInFinderClick.emitOnNext { [weak self] in
            guard let self else { return }
            guard let url = exportingState.destinationURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .disposed(by: rx.disposeBag)

        let rows = exportingState.$perImageOutcomes.asDriver().map { outcomes in
            outcomes.map { BatchExportingCompletionRowViewModel(outcome: $0) }
        }

        return Output(
            summaryText: $summaryText.asDriver(),
            rows: rows
        )
    }

    private func refreshFromState() {
        if let result = exportingState.aggregatedResult {
            summaryText = Self.makeSummary(from: result)
        }
    }

    private static func makeSummary(from result: BatchExportingAggregatedResult) -> String {
        let totalImages = result.imagesSucceeded + result.imagesFailed
        let imagesWord = totalImages == 1 ? "image" : "images"
        var lines: [String] = []
        if result.imagesFailed > 0 {
            lines.append("\(totalImages) \(imagesWord) processed · \(result.imagesSucceeded) succeeded · \(result.imagesFailed) failed")
        } else {
            lines.append("\(totalImages) \(imagesWord) exported successfully")
        }
        lines.append("\(result.interfacesSucceeded) interface\(result.interfacesSucceeded == 1 ? "" : "s") generated\(result.interfacesFailed > 0 ? " · \(result.interfacesFailed) failed" : "")")
        lines.append("ObjC: \(result.totalObjcCount) · Swift: \(result.totalSwiftCount)")
        lines.append(String(format: "Duration: %.1fs", result.totalDuration))
        return lines.joined(separator: "\n")
    }
}

extension BatchExportingCompletionViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Export Complete:"
    }

    var nextTitle: Driver<String> {
        "Done"
    }

    var isPreviousEnabled: Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        true
    }
}

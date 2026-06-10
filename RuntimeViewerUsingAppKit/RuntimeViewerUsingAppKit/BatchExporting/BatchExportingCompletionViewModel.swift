import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingCompletionViewModel: ViewModel<ExportingRoute> {
    struct Summary: Equatable {
        let hasFailures: Bool
        let headerTitle: String
        let headerSubtitle: String
        let interfacesValue: String
        let imagesValue: String
        let objcSwiftValue: String
        let durationValue: String

        static let empty = Summary(
            hasFailures: false,
            headerTitle: "Export Complete",
            headerSubtitle: "",
            interfacesValue: "—",
            imagesValue: "—",
            objcSwiftValue: "—",
            durationValue: "—"
        )
    }

    struct Input {
        let refresh: Signal<Void>
        let showInFinderClick: Signal<Void>
    }

    struct Output {
        let summary: Driver<Summary>
        let rows: Driver<[BatchExportingCompletionRowViewModel]>
    }

    @Observed private(set) var summary: Summary = .empty

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
                summary = Self.makeSummary(result: result, destinationURL: exportingState.destinationURL)
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
            summary: $summary.asDriver(),
            rows: rows
        )
    }

    private func refreshFromState() {
        if let result = exportingState.aggregatedResult {
            summary = Self.makeSummary(result: result, destinationURL: exportingState.destinationURL)
        }
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func formatInteger(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func makeSummary(result: BatchExportingAggregatedResult, destinationURL: URL?) -> Summary {
        let totalImages = result.imagesSucceeded + result.imagesFailed
        let totalInterfaces = result.interfacesSucceeded + result.interfacesFailed
        let hasFailures = result.imagesFailed > 0 || result.interfacesFailed > 0
        let imagesWord = totalImages == 1 ? "image" : "images"
        let headerTitle = hasFailures ? "Export Completed with Errors" : "Export Complete"
        let destinationText = destinationURL.map { "Exported to \(tildeAbbreviated($0.path))" } ?? "Export finished"
        let headerSubtitle: String
        if hasFailures {
            headerSubtitle = "\(result.imagesSucceeded) of \(totalImages) \(imagesWord) succeeded · \(destinationText)"
        } else {
            headerSubtitle = "\(totalImages) \(imagesWord) · \(destinationText)"
        }

        let interfacesValue: String
        if result.interfacesFailed > 0 {
            interfacesValue = "\(formatInteger(result.interfacesSucceeded)) / \(formatInteger(totalInterfaces))"
        } else {
            interfacesValue = formatInteger(result.interfacesSucceeded)
        }

        let imagesValue: String
        if result.imagesFailed > 0 {
            imagesValue = "\(result.imagesSucceeded) / \(totalImages)"
        } else {
            imagesValue = "\(totalImages)"
        }

        let objcSwiftValue = "\(formatInteger(result.totalObjcCount)) · \(formatInteger(result.totalSwiftCount))"
        let durationValue = String(format: "%.1f s", result.totalDuration)

        return Summary(
            hasFailures: hasFailures,
            headerTitle: headerTitle,
            headerSubtitle: headerSubtitle,
            interfacesValue: interfacesValue,
            imagesValue: imagesValue,
            objcSwiftValue: objcSwiftValue,
            durationValue: durationValue
        )
    }

    private static func tildeAbbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
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

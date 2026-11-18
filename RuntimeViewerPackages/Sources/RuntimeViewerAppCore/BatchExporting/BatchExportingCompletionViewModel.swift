#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore

public final class BatchExportingCompletionViewModel: ViewModel<ExportingRoute> {
    public struct Summary: Equatable {
        public let hasFailures: Bool
        public let headerTitle: String
        public let headerSubtitle: String
        public let interfacesValue: String
        public let imagesValue: String
        public let objcSwiftValue: String
        public let durationValue: String

        public static let empty = Summary(
            hasFailures: false,
            headerTitle: "Export Complete",
            headerSubtitle: "",
            interfacesValue: "—",
            imagesValue: "—",
            objcSwiftValue: "—",
            durationValue: "—"
        )
    }

    public struct Input {
        public let refresh: Signal<Void>
        public let showInFinderClick: Signal<Void>

        public init(refresh: Signal<Void>, showInFinderClick: Signal<Void>) {
            self.refresh = refresh
            self.showInFinderClick = showInFinderClick
        }
    }

    public struct Output {
        public let summary: Driver<Summary>
        public let rows: Driver<[BatchExportingCompletionRowViewModel]>
    }

    @RxObserved private(set) var summary: Summary = .empty

    @Dependency(\.finderClient) private var finderClient

    private let exportingState: BatchExportingState

    public init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    public func transform(_ input: Input) -> Output {
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
            finderClient.revealFile(url)
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
    public var title: Driver<String> {
        "Export Complete:"
    }

    public var nextTitle: Driver<String> {
        "Done"
    }

    public var isPreviousEnabled: Driver<Bool> {
        false
    }

    public var isNextEnabled: Driver<Bool> {
        true
    }
}

#endif

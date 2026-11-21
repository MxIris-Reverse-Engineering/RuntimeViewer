#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class ExportingCompletionViewModel: ViewModel<ExportingRoute> {
    public struct Input {
        public let refresh: Signal<Void>
        public let showInFinderClick: Signal<Void>

        public init(refresh: Signal<Void>, showInFinderClick: Signal<Void>) {
            self.refresh = refresh
            self.showInFinderClick = showInFinderClick
        }
    }

    public struct Output {
        public let summaryText: Driver<String>
    }

    @RxObserved private(set) var summaryText: String = ""

    @Dependency(\.finderClient) private var finderClient

    private let exportingState: ExportingState

    private func updateSummaryText(with result: RuntimeInterfaceExportResult) {
        var lines: [String] = []
        lines.append("\(result.succeeded) interfaces exported successfully")
        if result.failed > 0 {
            lines.append("\(result.failed) failed")
        }
        lines.append(String(format: "Duration: %.1fs", result.totalDuration))
        var languageCounts = "ObjC: \(result.objcCount) | Swift: \(result.swiftCount)"
        if result.cPlusPlusCount > 0 {
            languageCounts += " | C++: \(result.cPlusPlusCount)"
        }
        lines.append(languageCounts)
        summaryText = lines.joined(separator: "\n")
    }

    public init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func refreshFromState() {
        guard let result = exportingState.exportResult else { return }
        updateSummaryText(with: result)
    }

    public func transform(_ input: Input) -> Output {
        exportingState.$exportResult
            .asObservable()
            .compactMap { $0 }
            .subscribeOnNext { [weak self] result in
                guard let self else { return }
                updateSummaryText(with: result)
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

        return Output(
            summaryText: $summaryText.asDriver()
        )
    }
}

extension ExportingCompletionViewModel: ExportingStepViewModel {
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

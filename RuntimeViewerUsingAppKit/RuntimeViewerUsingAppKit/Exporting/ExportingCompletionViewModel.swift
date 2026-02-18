import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingCompletionViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let refresh: Signal<Void>
        let showInFinderClick: Signal<Void>
    }

    struct Output {
        let summaryText: Driver<String>
    }

    @Observed private(set) var summaryText: String = ""

    private let exportingState: ExportingState

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func refreshFromState() {
        guard let result = exportingState.exportResult else { return }
        var lines: [String] = []
        lines.append("\(result.succeeded) interfaces exported successfully")
        if result.failed > 0 {
            lines.append("\(result.failed) failed")
        }
        lines.append(String(format: "Duration: %.1fs", result.totalDuration))
        lines.append("ObjC: \(result.objcCount) | Swift: \(result.swiftCount)")
        summaryText = lines.joined(separator: "\n")
    }

    func transform(_ input: Input) -> Output {
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

        return Output(
            summaryText: $summaryText.asDriver()
        )
    }
}

extension ExportingCompletionViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Export Complete:"
    }

    var nextTitle: Driver<String> {
        "Done"
    }

    var isPreviousEnabled: RxCocoa.Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        true
    }
}

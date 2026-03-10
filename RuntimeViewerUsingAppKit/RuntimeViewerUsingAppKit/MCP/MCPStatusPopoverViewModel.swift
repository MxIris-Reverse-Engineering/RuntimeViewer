import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerMCPBridge

final class MCPStatusPopoverViewModel<Route: Routable>: ViewModel<Route> {
    @Observed private(set) var state: MCPServerState = MCPService.shared.serverState

    private let openSettingsRelay = PublishRelay<Void>()

    struct Input {
        let actionButtonClick: Signal<Void>
        let copyPortClick: Signal<Void>
    }

    struct Output {
        let state: Driver<MCPServerState>
        let openSettings: Signal<Void>
    }

    func transform(_ input: Input) -> Output {
        MCPService.shared.onStateChange = { [weak self] newState in
            guard let self else { return }
            state = newState
        }

        input.actionButtonClick.emitOnNext { [weak self] in
            guard let self else { return }
            switch state {
            case .disabled:
                openSettingsRelay.accept(())
            case .stopped:
                MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
            case .running:
                MCPService.shared.stop()
            }
        }
        .disposed(by: rx.disposeBag)

        input.copyPortClick.emitOnNext { [weak self] in
            guard let self else { return }
            guard let port = state.port else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(port)", forType: .string)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver(),
            openSettings: openSettingsRelay.asSignal()
        )
    }
}

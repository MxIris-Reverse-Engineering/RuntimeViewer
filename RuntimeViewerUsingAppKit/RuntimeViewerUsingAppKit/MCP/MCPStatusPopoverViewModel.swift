import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerMCPBridge

enum MCPConfigType {
    case claudeCode
    case codex
    case json

    func configString(port: UInt16) -> String {
        let url = "http://127.0.0.1:\(port)/mcp"
        switch self {
        case .claudeCode:
            return "claude mcp add RuntimeViewer --transport http --url \(url)"
        case .codex:
            return "codex mcp add RuntimeViewer --transport http --url \(url)"
        case .json:
            return """
            {
              "mcpServers": {
                "RuntimeViewer": {
                  "type": "http",
                  "url": "\(url)"
                }
              }
            }
            """
        }
    }
}

final class MCPStatusPopoverViewModel<Route: Routable>: ViewModel<Route> {
    @Observed private(set) var state: MCPServerState = MCPService.shared.serverState

    private let openSettingsRelay = PublishRelay<Void>()

    struct Input {
        let actionButtonClick: Signal<Void>
        let copyPortClick: Signal<Void>
        let copyConfig: Signal<MCPConfigType>
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

        input.copyConfig.emitOnNext { [weak self] configType in
            guard let self else { return }
            guard let port = state.port else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(configType.configString(port: port), forType: .string)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver(),
            openSettings: openSettingsRelay.asSignal()
        )
    }
}

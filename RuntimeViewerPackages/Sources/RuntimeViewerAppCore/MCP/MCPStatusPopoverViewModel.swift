#if os(macOS)

import Foundation
import RuntimeViewerArchitectures

public final class MCPStatusPopoverViewModel<Route: Routable>: ViewModel<Route> {
    @Dependency(\.mcpServerClient) private var mcpServerClient

    @RxObserved private(set) var state: MCPServerState = .stopped

    public struct Input {
        public let actionButtonClick: Signal<Void>
        public let copyPortClick: Signal<Void>
        public let copyConfig: Signal<MCPConfigType>

        public init(actionButtonClick: Signal<Void>, copyPortClick: Signal<Void>, copyConfig: Signal<MCPConfigType>) {
            self.actionButtonClick = actionButtonClick
            self.copyPortClick = copyPortClick
            self.copyConfig = copyConfig
        }
    }

    public struct Output {
        public let state: Driver<MCPServerState>
    }

    public func transform(_ input: Input) -> Output {
        // Captured here rather than resolved inside the tracked closure, which re-arms on a
        // main-queue hop where the dependency context is gone.
        let mcpServerClient = self.mcpServerClient
        Observable<MCPServerState>
            .tracking {
                MainActor.assumeIsolated { mcpServerClient.state() }
            }
            .distinctUntilChanged()
            .bind(to: $state)
            .disposed(by: rx.disposeBag)

        input.actionButtonClick.emitOnNext { [weak self] in
            guard let self else { return }
            switch state {
            case .disabled:
                appRouter.trigger(.settings)
            case .stopped:
                mcpServerClient.start()
            case .running:
                mcpServerClient.stop()
            }
        }
        .disposed(by: rx.disposeBag)

        input.copyPortClick.emitOnNext { [weak self] in
            guard let self else { return }
            guard let port = state.port else { return }
            pasteboardClient.copyString("\(port)")
        }
        .disposed(by: rx.disposeBag)

        input.copyConfig.emitOnNext { [weak self] configType in
            guard let self else { return }
            guard let port = state.port else { return }
            pasteboardClient.copyString(configType.configString(port: port))
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver()
        )
    }
}

#endif

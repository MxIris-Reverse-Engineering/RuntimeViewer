import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient

@Loggable(.private)
final class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<any RunningItem>
        let cancel: Signal<Void>
    }

    struct Output {}

    enum Error: LocalizedError {
        case sandboxAppNoSupported

        var errorDescription: String? {
            "Sandbox apps are not currently supported"
        }
    }

    @Dependency(\.runtimeInjectClient)
    private var runtimeInjectClient
    
    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)
        input.attachToProcess.emitOnNext { [weak self] runningItem in
            guard let self else { return }

            let name = runningItem.name

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await runtimeInjectClient.installServerFrameworkIfNeeded()
                    guard let dylibURL = Bundle(url: runtimeInjectClient.serverFrameworkDestinationURL)?.executableURL else { return }
                    
                    switch runningItem {
                    case let runningApplication as RunningApplication:
                        try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: runningApplication.bundleIdentifier ?? name, isSandbox: runningApplication.isSandboxed)
                    case let runningProcess as RunningProcess:
                        try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: name, isSandbox: runningProcess.isSandboxed)
                    default:
                        return
                    }
                    
                    try await runtimeInjectClient.injectApplication(pid: runningItem.processIdentifier, dylibURL: dylibURL)
                    router.trigger(.dismiss)
                } catch {
                    switch runningItem {
                    case let runningApplication as RunningApplication:
                        runtimeEngineManager.terminateAttachedRuntimeEngine(name: name, identifier: runningApplication.bundleIdentifier ?? name, isSandbox: runningApplication.isSandboxed)
                    case let runningProcess as RunningProcess:
                        runtimeEngineManager.terminateAttachedRuntimeEngine(name: name, identifier: name, isSandbox: runningProcess.isSandboxed)
                    default:
                        return
                    }
                    
                    #log(.error, "\(error, privacy: .public)")
                    errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        return Output()
    }
}

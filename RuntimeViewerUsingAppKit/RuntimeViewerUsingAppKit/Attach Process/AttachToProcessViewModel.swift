import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient

final class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<NSRunningApplication>
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
        input.attachToProcess.emit(onNext: { [weak self] application in
            guard let self,
                  let name = application.localizedName,
                  let bundleIdentifier = application.bundleIdentifier
            else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await runtimeInjectClient.installServerFrameworkIfNeeded()
                    guard let dylibURL = Bundle(url: runtimeInjectClient.serverFrameworkDestinationURL)?.executableURL else { return }
                    try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: bundleIdentifier, isSandbox: application.isSandbox)
                    try await runtimeInjectClient.injectApplication(pid: application.processIdentifier, dylibURL: dylibURL)
                    router.trigger(.dismiss)
                } catch {
                    runtimeEngineManager.terminateAttachedRuntimeEngine(name: name, identifier: bundleIdentifier, isSandbox: application.isSandbox)
                    logger.error("\(error, privacy: .public)")
                    errorRelay.accept(error)
                }
            }
        }).disposed(by: rx.disposeBag)

        return Output()
    }
}

private import LaunchServicesPrivate

extension NSRunningApplication {
    fileprivate var applicationProxy: LSApplicationProxy? {
        guard let bundleIdentifier else { return nil }
        return LSApplicationProxy(forIdentifier: bundleIdentifier)
    }

    fileprivate var isSandbox: Bool {
        guard let entitlements = applicationProxy?.entitlements else { return false }
        guard let isSandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool else { return false }
        return isSandboxed
    }
}

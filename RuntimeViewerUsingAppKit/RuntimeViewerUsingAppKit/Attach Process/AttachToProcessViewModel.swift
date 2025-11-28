import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

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
    
    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)
        input.attachToProcess.emit(onNext: { [weak self] app in
            guard let self,
                  let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier
            else { return }

            Task { [weak self] in
                guard let self else { return }
                
                do {
                    if app.isSandbox {
                        self.errorRelay.accept(Error.sandboxAppNoSupported)
                        return
                    }
                    try await RuntimeInjectClient.shared.installServerFrameworkIfNeeded()
                    guard let dylibURL = Bundle(url: RuntimeInjectClient.shared.serverFrameworkDestinationURL)?.executableURL else { return }
                    try await RuntimeEngineManager.shared.launchAttachedRuntimeEngine(name: name, identifier: bundleIdentifier, isSandbox: app.isSandbox)
                    try await RuntimeInjectClient.shared.injectApplication(pid: app.processIdentifier, dylibURL: dylibURL)
                    await MainActor.run {
                        self.router.trigger(.dismiss)
                    }
                } catch {
                    print(error, error.localizedDescription)
                    await MainActor.run {
                        self.errorRelay.accept(error)
                    }
                }
            }
        }).disposed(by: rx.disposeBag)
        
        return Output()
    }
}

import LaunchServicesPrivate

extension NSRunningApplication {
    var applicationProxy: LSApplicationProxy? {
        guard let bundleIdentifier else { return nil }
        return LSApplicationProxy(forIdentifier: bundleIdentifier)
    }

    var isSandbox: Bool {
        guard let entitlements = applicationProxy?.entitlements else { return false }
        guard let isSandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool else { return false }
        return isSandboxed
    }
}

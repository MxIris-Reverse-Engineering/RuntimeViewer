import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures

enum ExportingRoute: Routable {
    case initial
    case previous
    case next
    case cancel
    case directoryPicker
}

typealias ExportingTransition = Transition<ExportingWindowController, ExportingViewController>

final class ExportingCoordinator: SceneCoordinator<ExportingRoute, ExportingTransition> {
    let exportingState: ExportingState

    let documentState: DocumentState

    init?(documentState: DocumentState) {
        guard let imageName = documentState.currentImageName,
              let imagePath = documentState.currentImagePath
        else { return nil }
        self.exportingState = .init(imagePath: imagePath, imageName: imageName)
        self.documentState = documentState
        super.init(windowController: .init(), initialRoute: nil)
        windowController.contentViewController = ExportingViewController(router: self)
        contextTrigger(.initial)
    }

    override func prepareTransition(for route: ExportingRoute) -> ExportingTransition {
        switch route {
        case .initial:
            let configurationViewController = ExportingConfigurationViewController()
            let configurationViewModel = ExportingConfigurationViewModel(exportingState: exportingState, documentState: documentState, router: self)
            configurationViewController.setupBindings(for: configurationViewModel)

            let progressViewController = ExportingProgressViewController()
            let progressViewModel = ExportingProgressViewModel(exportingState: exportingState, documentState: documentState, router: self)
            progressViewController.setupBindings(for: progressViewModel)

            let completionViewController = ExportingCompletionViewController()
            let completionViewModel = ExportingCompletionViewModel(exportingState: exportingState, documentState: documentState, router: self)
            completionViewController.setupBindings(for: completionViewModel)

            return .multiple(
                .set([configurationViewController, progressViewController, completionViewController]),
                .select(index: 0)
            )
        case .previous:
            switch exportingState.currentStep {
            case .configuration:
                break
            case .progress:
                exportingState.destinationURL = nil
                exportingState.currentStep = .configuration
            case .completion:
                break
            }
            return .select(index: exportingState.currentStep.rawValue)
        case .next:
            switch exportingState.currentStep {
            case .configuration:
                if exportingState.destinationURL == nil {
                    contextTrigger(.directoryPicker)
                    return .none()
                } else {
                    exportingState.currentStep = .progress
                }
            case .progress:
                exportingState.currentStep = .completion
            case .completion:
                return .endSheetOnTop()
            }
            return .select(index: exportingState.currentStep.rawValue)
        case .cancel:
            return .endSheetOnTop()
        case .directoryPicker:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.directory]
            panel.canCreateDirectories = true
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.beginSheetModal(for: windowController.contentWindow) { [weak self, weak panel] result in
                guard result == .OK, let self, let panel, let url = panel.url else { return }
                exportingState.destinationURL = url
                contextTrigger(.next)
            }
            return .none()
        }
    }
}

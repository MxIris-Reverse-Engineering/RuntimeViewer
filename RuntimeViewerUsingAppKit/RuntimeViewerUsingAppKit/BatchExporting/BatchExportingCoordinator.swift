import AppKit
import FoundationToolbox
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

@Loggable(.private)
final class BatchExportingCoordinator: SceneCoordinator<ExportingRoute, ExportingTransition> {
    let exportingState: BatchExportingState

    let documentState: DocumentState

    init(documentState: DocumentState) {
        self.exportingState = .init()
        self.documentState = documentState
        super.init(windowController: .init(), initialRoute: nil)
        windowController.contentViewController = ExportingViewController(router: self)
        contextTrigger(.initial)
        loadAvailableImages()
    }

    private func loadAvailableImages() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let imageTree = BatchExportingImageTree(imageRootNodes: documentState.runtimeEngine.imageNodes)
            exportingState.availableImages = imageTree.imageNodes.compactMap { imageNode in
                imageNode.imagePath.map { BatchExportingImage(path: $0, name: imageNode.name) }
            }
            exportingState.imageTree = imageTree
        }
    }

    override func prepareTransition(for route: ExportingRoute) -> ExportingTransition {
        switch route {
        case .initial:
            let imageSelectionViewController = BatchExportingImageSelectionViewController()
            let imageSelectionViewModel = BatchExportingImageSelectionViewModel(exportingState: exportingState, documentState: documentState, router: self)
            imageSelectionViewController.setupBindings(for: imageSelectionViewModel)

            let configurationViewController = BatchExportingConfigurationViewController()
            let configurationViewModel = BatchExportingConfigurationViewModel(exportingState: exportingState, documentState: documentState, router: self)
            configurationViewController.setupBindings(for: configurationViewModel)

            let progressViewController = BatchExportingProgressViewController()
            let progressViewModel = BatchExportingProgressViewModel(exportingState: exportingState, documentState: documentState, router: self)
            progressViewController.setupBindings(for: progressViewModel)

            let completionViewController = BatchExportingCompletionViewController()
            let completionViewModel = BatchExportingCompletionViewModel(exportingState: exportingState, documentState: documentState, router: self)
            completionViewController.setupBindings(for: completionViewModel)

            return .multiple(
                .set([imageSelectionViewController, configurationViewController, progressViewController, completionViewController]),
                .select(index: 0)
            )
        case .previous:
            switch exportingState.currentStep {
            case .imageSelection:
                break
            case .configuration:
                exportingState.currentStep = .imageSelection
            case .progress:
                exportingState.destinationURL = nil
                exportingState.currentStep = .configuration
            case .completion:
                break
            }
            return .select(index: exportingState.currentStep.rawValue)
        case .next:
            switch exportingState.currentStep {
            case .imageSelection:
                exportingState.currentStep = .configuration
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
                removeFromParent()
                return .endSheetOnTop()
            }
            return .select(index: exportingState.currentStep.rawValue)
        case .cancel:
            removeFromParent()
            return .endSheetOnTop()
        case .directoryPicker:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.directory]
            panel.canCreateDirectories = true
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.beginSheetModal(for: rootWindowController.contentWindow) { [weak self, weak panel] result in
                guard result == .OK, let self, let panel, let url = panel.url else { return }
                exportingState.destinationURL = url
                contextTrigger(.next)
            }
            return .none()
        }
    }
}

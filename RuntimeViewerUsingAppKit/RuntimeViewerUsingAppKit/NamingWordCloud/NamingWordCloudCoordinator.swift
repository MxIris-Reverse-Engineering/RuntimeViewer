import AppKit
import UniformTypeIdentifiers
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias NamingWordCloudTransition = Transition<NamingWordCloudWindowController, NamingWordCloudViewController>

/// One image's naming word cloud window. `MainCoordinator` keeps one per image
/// of its document, brings it forward when it is asked for again, and closes
/// it with the document.
final class NamingWordCloudCoordinator: SceneCoordinator<NamingWordCloudRoute, NamingWordCloudTransition> {
    let imagePath: String

    /// Called once the window has closed, so that the owner lets this go.
    var windowClosingHandler: (() -> Void)?

    private let documentState: DocumentState

    private var viewModel: NamingWordCloudViewModel?

    private var viewController: NamingWordCloudViewController?

    private var windowCloseObservation: NSObjectProtocol?

    /// The scene's window controller, typed: `SceneCoordinator` hands it back as its superclass.
    private let namingWordCloudWindowController: NamingWordCloudWindowController

    init(imagePath: String, documentState: DocumentState) {
        self.imagePath = imagePath
        self.documentState = documentState
        let windowController = NamingWordCloudWindowController()
        namingWordCloudWindowController = windowController
        super.init(windowController: windowController, initialRoute: nil)
        installRootContent()
    }

    // MARK: - Window

    func showWindow() {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        windowController.close()
    }

    private func installRootContent() {
        let viewModel = NamingWordCloudViewModel(imagePath: imagePath, documentState: documentState, router: self)
        let viewController = NamingWordCloudViewController()
        viewController.setupBindings(for: viewModel)
        windowController.contentViewController = viewController
        namingWordCloudWindowController.configure(
            title: viewModel.windowTitle,
            subtitle: viewModel.windowSubtitle,
            autosaveName: "NamingWordCloud \(viewModel.imageName)",
            toolbarDelegate: viewController
        )
        self.viewModel = viewModel
        self.viewController = viewController
        windowCloseObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: windowController.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowClosingHandler?()
            }
        }
    }

    // MARK: - Transitions

    override func prepareTransition(for route: NamingWordCloudRoute) -> NamingWordCloudTransition {
        switch route {
        case .export(let format):
            presentSavePanel(for: format)
            return .none()
        case .editCompoundWords:
            let viewController = NamingCompoundWordsViewController()
            let viewModel = NamingCompoundWordsViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asSheet)
        case .closeCompoundWords:
            return .dismiss()
        }
    }

    // MARK: - Export

    /// Asks where to save, as a sheet on the window, then writes: the whole
    /// canvas for the image, the view model's counts for the rest.
    private func presentSavePanel(for format: NamingWordCloudExportFormat) {
        guard let window = windowController.window, let viewModel else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = viewModel.suggestedFileName(for: format)
        savePanel.allowedContentTypes = [Self.contentType(of: format)]
        savePanel.canCreateDirectories = true
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let fileURL = savePanel.url else { return }
            do {
                let data: Data?
                switch format {
                case .image:
                    data = viewController?.wordCloudPNGData()
                case .csv, .json:
                    data = try self.viewModel?.exportedData(as: format)
                }
                guard let data else { throw ExportError() }
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private static func contentType(of format: NamingWordCloudExportFormat) -> UTType {
        switch format {
        case .image: .png
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }

    private struct ExportError: LocalizedError {
        var errorDescription: String? { "There was nothing to export." }
    }
}

import UIKit
import UniformTypeIdentifiers
import Dependencies
import DependenciesMacros
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerApplication

/// Opens Mach-O files, bundles, folders and dyld shared caches from disk, the
/// counterpart of the macOS app's `FileController`: the open button's document
/// picker, Open Path… on the jailbroken app, and files other apps hand over
/// (Open In, a scene's URL contexts).
///
/// The file is read in this process (`RuntimeFileOpener`), so a file that
/// cannot be read is known before any window opens, and the user is told why
/// in the window they opened it from. A file that was read opens in a window
/// of its own where the device shows several (iPad, visionOS), and over the
/// window it was opened from on an iPhone, with a close button that goes back
/// to it.
@Loggable
@MainActor
final class FileController: NSObject {
    fileprivate static let shared = FileController()

    /// Whether this app reads any path on the device: it has no container,
    /// so no sandbox — the jailbroken variant (`no-container`, `no-sandbox`).
    /// Decided at run time, as every capability of the iOS-family apps is.
    static let opensAbsolutePaths: Bool = !NSHomeDirectory().contains("/Containers/Data/Application/")

    @Dependency(\.runtimeFileOpener) private var runtimeFileOpener

    @Dependency(\.runtimeFileEngineParking) private var runtimeFileEngineParking

    @Dependency(\.documentSessionRegistry) private var documentSessionRegistry

    /// A file window stacked over another window on an iPhone: its
    /// coordinator, which nothing else holds, and its document session.
    private struct StackedFileWindow {
        let coordinator: MainCoordinator
        let session: DocumentSession
    }

    /// The stacked file windows, by their coordinator, until they close.
    private var stackedFileWindowsByCoordinator: [ObjectIdentifier: StackedFileWindow] = [:]

    /// The view controller the document picker on screen was presented from,
    /// which a file the user picks opens over.
    private weak var documentPickerPresenter: UIViewController?

    private override init() {
        super.init()
    }

    /// Lets a file go thirty seconds after its last window closed.
    func start() {
        runtimeFileEngineParking.start()
    }

    /// The open button: the system's document picker, for a file, a bundle
    /// or a folder.
    func chooseFile(presentingFrom viewController: UIViewController) {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: false)
        documentPicker.allowsMultipleSelection = false
        documentPicker.delegate = self
        let presenter = Self.topmostViewController(from: viewController)
        documentPickerPresenter = presenter
        presenter.present(documentPicker, animated: true)
    }

    /// Open Path…: an absolute path, typed or pasted. Only where
    /// ``opensAbsolutePaths``.
    func enterPath(presentingFrom viewController: UIViewController) {
        let alert = UIAlertController(title: "Open Path", message: "The absolute path of a Mach-O file, a bundle, a folder or a dyld shared cache.", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "/System/Library/Frameworks/UIKit.framework"
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
            textField.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self, weak alert, weak viewController] _ in
            guard let self, let viewController,
                  let path = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return }
            open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), presentingFrom: viewController)
        })
        Self.topmostViewController(from: viewController).present(alert, animated: true)
    }

    /// Files another app handed this one — Open In from Files — shown over
    /// `viewController`'s window.
    func open(_ urlContexts: Set<UIOpenURLContext>, presentingFrom viewController: UIViewController) {
        // One window at a time: the picker and Open In hand over one file.
        guard let url = urlContexts.first?.url, url.isFileURL else { return }
        open(url, presentingFrom: viewController)
    }

    /// Reads the file at `url`, then shows it in a window of its own, or says
    /// over `viewController` why it could not be read.
    func open(_ url: URL, presentingFrom viewController: UIViewController) {
        Task { [weak self, weak viewController] in
            guard let self else { return }
            do {
                let engine = try await runtimeFileOpener.startReading(fileAt: url)
                #log(.info, "Opened \(url.lastPathComponent, privacy: .public) from disk")
                guard let viewController else { return }
                showWindow(on: engine, presentingFrom: viewController)
            } catch {
                #log(.error, "Could not open \(url.lastPathComponent, privacy: .public) from disk: \(error.localizedDescription, privacy: .public)")
                guard let viewController else { return }
                presentFailure(error, openingFileNamed: url.lastPathComponent, over: viewController)
            }
        }
    }

    private func showWindow(on engine: RuntimeEngine, presentingFrom viewController: UIViewController) {
        if UIApplication.shared.supportsMultipleScenes {
            // A window of its own, which takes the engine back from the
            // registry as it connects (SceneDelegate).
            let requestIdentifier = documentSessionRegistry.reserveWindow(on: engine)
            let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: FileWindowActivity.make(requestIdentifier: requestIdentifier))
            UIApplication.shared.activateSceneSession(for: request) { [weak self, weak viewController] error in
                Task { @MainActor [weak self, weak viewController] in
                    guard let self else { return }
                    documentSessionRegistry.cancelReservation(requestIdentifier)
                    #log(.error, "Could not open a window for \(engine.source.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    guard let viewController else { return }
                    presentFailure(error, openingFileNamed: engine.source.description, over: viewController)
                }
            }
        } else {
            // An iPhone: over the window it was opened from, until its close
            // button takes it away.
            let session = DocumentSession(runtimeEngine: engine)
            session.open()
            let coordinator = MainCoordinator(documentState: session.documentState, isFileWindow: true)
            coordinator.delegate = self
            stackedFileWindowsByCoordinator[ObjectIdentifier(coordinator)] = StackedFileWindow(coordinator: coordinator, session: session)
            coordinator.rootViewController.modalPresentationStyle = .fullScreen
            coordinator.trigger(.initial)
            Self.topmostViewController(from: viewController).present(coordinator.rootViewController, animated: true)
        }
    }

    private func presentFailure(_ error: any Error, openingFileNamed fileName: String, over viewController: UIViewController) {
        let alert = UIAlertController(title: "“\(fileName)” could not be opened.", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        Self.topmostViewController(from: viewController).present(alert, animated: true)
    }

    /// What a new sheet goes over: the view controller presented last on
    /// `viewController`'s chain.
    private static func topmostViewController(from viewController: UIViewController) -> UIViewController {
        var topmost = viewController
        while let presented = topmost.presentedViewController, !presented.isBeingDismissed {
            topmost = presented
        }
        return topmost
    }
}

extension FileController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let presenter = documentPickerPresenter else { return }
        documentPickerPresenter = nil
        open(url, presentingFrom: presenter)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        documentPickerPresenter = nil
    }
}

extension FileController: MainCoordinatorDelegate {
    /// A stacked file window's close button: back to the window under it.
    func mainCoordinatorDidRequestClose(_ mainCoordinator: MainCoordinator) {
        guard let stackedFileWindow = stackedFileWindowsByCoordinator.removeValue(forKey: ObjectIdentifier(mainCoordinator)) else { return }
        stackedFileWindow.session.close()
        mainCoordinator.rootViewController.presentingViewController?.dismiss(animated: true)
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { FileController.shared })
    var fileController: FileController
}

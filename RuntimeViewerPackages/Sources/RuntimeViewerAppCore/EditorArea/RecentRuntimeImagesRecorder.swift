import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Records into a document's engine's recent images (`RecentRuntimeImages`) every image the
/// document uses — the image the sidebar goes into, an image page the focused editor pane shows —
/// and every object the focused pane shows, under its image; an empty editor pane's start page
/// lists them (proposal `editor-start-page`).
///
/// Objects follow `DocumentState.selectedRuntimeObject`, which is the focused pane's active tab's
/// object whatever put it there — a click in any list, a link, a tab or pane switch, Back and
/// Forward — so an object the user comes back to moves to the front, as a file Xcode shows again
/// does. An empty tab records nothing. The same object shown in a new form — a type that has grown
/// a specialization — is not shown again, and does not move; nor does the focus moving to another
/// pane that shows the same object. It is recorded again, in the form then on screen, once
/// something else — another object, an empty tab — has been on screen in between. Images follow
/// `DocumentState.currentImageNode` and the focused pane's active tab's image page the same way.
///
/// The engine is read when an object or an image arrives, never paired with it ahead of time: an
/// engine switch empties the editor area and takes the sidebar back to its image list, so nothing
/// of one engine is ever filed under another. Image paths are filed in canonical form
/// (`RuntimeEngine.canonicalImagePath(_:)`), the form an object's `imagePath` has; since an engine
/// learns that form only after it connects, a record first folds into its image the entries filed
/// under the image's other spelling before then
/// (`RecentRuntimeImages.foldingOtherSpellings(of:in:canonicalImagePath:)`).
///
/// `DocumentSession.open()` makes one per window. Make it where the dependencies it should write
/// through are in effect: `@Dependency` takes them when it is made.
@MainActor
final class RecentRuntimeImagesRecorder {
    @Dependency(\.appDefaults)
    private var appDefaults

    private let disposeBag = DisposeBag()

    init(documentState: DocumentState) {
        documentState.$selectedRuntimeObject
            .asObservable()
            .distinctUntilChanged()
            .compactMap { $0 }
            .subscribeOnNext { [weak self, weak documentState] object in
                guard let self, let documentState else { return }
                record(on: documentState.runtimeEngine, imagePath: object.imagePath) { recentImages, imagesByEngine in
                    recentImages.recording(object, in: imagesByEngine)
                }
            }
            .disposed(by: disposeBag)

        let sidebarImagePaths = documentState.$currentImageNode
            .asObservable()
            .map { $0?.path }
            .distinctUntilChanged()
        let imagePagePaths = documentState.$editorArea
            .asObservable()
            .map { $0.focusedPane.activeTab.imagePath }
            .distinctUntilChanged()
        for imagePaths in [sidebarImagePaths, imagePagePaths] {
            imagePaths
                .compactMap { $0 }
                .subscribeOnNext { [weak self, weak documentState] imagePath in
                    guard let self, let documentState else { return }
                    let engine = documentState.runtimeEngine
                    let canonicalImagePath = engine.canonicalImagePath(imagePath)
                    record(on: engine, imagePath: canonicalImagePath) { recentImages, imagesByEngine in
                        recentImages.recordingImage(at: canonicalImagePath, in: imagesByEngine)
                    }
                }
                .disposed(by: disposeBag)
        }
    }

    /// Writes what `update` makes of the engine's recent images, once the entries filed under
    /// another spelling of the image at `imagePath` — a canonical path — are folded into it, unless
    /// neither changes anything.
    private func record(
        on engine: RuntimeEngine,
        imagePath: String,
        _ update: (RecentRuntimeImages, [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]]?
    ) {
        let recentImages = RecentRuntimeImages(engine: engine)
        let storedImagesByEngine = appDefaults.recentRuntimeImagesByEngine
        let foldedImagesByEngine = recentImages.foldingOtherSpellings(of: imagePath, in: storedImagesByEngine) { engine.canonicalImagePath($0) }
        guard let updatedImagesByEngine = update(recentImages, foldedImagesByEngine ?? storedImagesByEngine) ?? foldedImagesByEngine else { return }
        appDefaults.recentRuntimeImagesByEngine = updatedImagesByEngine
    }
}

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Records every object a document's focused editor pane shows into its engine's recent objects
/// (`RecentRuntimeObjects`), which the start page of an empty pane lists (proposal
/// `editor-start-page`).
///
/// It follows `DocumentState.selectedRuntimeObject`, which is the focused pane's active tab's
/// object whatever put it there — a click in any list, a link, a tab or pane switch, Back and
/// Forward — so an object the user comes back to moves to the front, as a file Xcode shows again
/// does. An empty tab records nothing. The same object shown in a new form — a type that has grown
/// a specialization — is not shown again, and does not move; nor does the focus moving to another
/// pane that shows the same object. It is recorded again, in the form then on screen, once
/// another object has been shown in between. The engine is read when an object
/// arrives, never paired with it ahead of time: an engine switch empties the editor area, so no
/// object of one engine is ever filed under another.
///
/// `DocumentSession.open()` makes one per window. Make it where the dependencies it should write
/// through are in effect: `@Dependency` takes them when it is made.
@MainActor
final class RecentRuntimeObjectsRecorder {
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
                record(object, on: documentState.runtimeEngine)
            }
            .disposed(by: disposeBag)
    }

    private func record(_ object: RuntimeObject, on engine: RuntimeEngine) {
        let recentObjects = RecentRuntimeObjects(engine: engine)
        guard let updatedObjectsByEngine = recentObjects.recording(object, in: appDefaults.recentRuntimeObjectsByEngine) else { return }
        appDefaults.recentRuntimeObjectsByEngine = updatedObjectsByEngine
    }
}

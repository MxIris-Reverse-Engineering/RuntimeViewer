import Foundation
import RuntimeViewerArchitectures
import MemberwiseInit

/// The editor area's view model: the pane the keyboard focus went into becomes
/// the focused pane, as an Xcode editor pane becomes the last active one when
/// the first responder enters it.
public final class EditorAreaViewModel: ViewModel<EditorAreaRoute> {
    @MemberwiseInit(.public)
    public struct Input {
        /// The pane the window's first responder went into — a click in its
        /// text, or a tab into it.
        public let paneReceivedKeyboardFocus: Signal<EditorPane.ID>
    }

    public struct Output {}

    public func transform(_ input: Input) -> Output {
        input.paneReceivedKeyboardFocus.emitOnNext { [weak self] paneID in
            guard let self else { return }
            documentState.selectionRouter.trigger(.focusEditorPane(paneID))
        }
        .disposed(by: rx.disposeBag)

        return Output()
    }
}

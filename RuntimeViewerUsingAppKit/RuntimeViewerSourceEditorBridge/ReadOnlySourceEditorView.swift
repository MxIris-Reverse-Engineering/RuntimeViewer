// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them. iOS only: it is the UIKit build's
// editor view.
#if os(iOS) && arch(arm64) && canImport(SourceEditor)

import UIKit
internal import SourceEditor

/// The UIKit build's `SourceEditorView` for a text that cannot be edited, without the software
/// keyboard.
///
/// The framework brings the keyboard up on a tap: `SetSelectionRange` makes the view the first
/// responder, and a double tap runs `ShowKeyboard` (`iOS/EventHandling/Actions/SetSelectionRange.swift`
/// and `SourceEditorView.swift`, reconstruction 26.6.10). `canBecomeFirstResponder` only checks
/// `isInteractive`, and nothing in the framework keeps the keyboard down when editing is disabled.
/// Turning `isInteractive` off would tear down the selection and find interactions with it, so the
/// view stays interactive — it still becomes first responder, which the system find navigator and
/// the selection need — and asks for an empty input view instead of the keyboard. Typing could not
/// change the text anyway: `isEditingEnabled` is false, and `replaceTextInRange` checks it through
/// `isEditableInRange`.
final class ReadOnlySourceEditorView: SourceEditorView {
    /// Zero-sized, so nothing slides up where the keyboard would.
    private let emptyInputView = UIView(frame: .zero)

    override var inputView: UIView? {
        emptyInputView
    }
}

#endif

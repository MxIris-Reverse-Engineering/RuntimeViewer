#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// What the content panes look up at a character index of their text, for the
/// right-click menu and for the insertion point. AppKit hands them the
/// insertion point's index, which is the text's length after its last
/// character — a click below the last line, or in an empty or still loading
/// pane — and asking for an attribute there raises `NSRangeException`, so
/// these answer nothing outside the text.
extension NSAttributedString {
    /// The object the token at `characterIndex` links to: the jump target the
    /// generator recorded for it.
    public func linkedRuntimeObject(at characterIndex: Int) -> RuntimeObject? {
        attributeInsideText(.link, at: characterIndex) as? RuntimeObject
    }

    /// The member the line holding `characterIndex` declares, if it declares
    /// one with code (`ContentTextViewModel.markingDeclaredMembers(in:of:)`).
    public func declaredMember(at characterIndex: Int) -> RuntimeMemberReference? {
        attributeInsideText(.runtimeViewerDeclaredMember, at: characterIndex) as? RuntimeMemberReference
    }

    private func attributeInsideText(_ key: NSAttributedString.Key, at characterIndex: Int) -> Any? {
        guard characterIndex >= 0, characterIndex < length else { return nil }
        return attribute(key, at: characterIndex, effectiveRange: nil)
    }
}

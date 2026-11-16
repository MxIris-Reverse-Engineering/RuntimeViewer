#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

extension NSAttributedString {
    /// The object the token at `characterIndex` links to: the jump target the
    /// generator recorded for it.
    public func linkedRuntimeObject(at characterIndex: Int) -> RuntimeObject? {
        attribute(.link, at: characterIndex, effectiveRange: nil) as? RuntimeObject
    }

    /// The member the line holding `characterIndex` declares, if it declares
    /// one with code (`ContentTextViewModel.markingDeclaredMembers(in:of:)`).
    public func declaredMember(at characterIndex: Int) -> RuntimeMemberReference? {
        attribute(.runtimeViewerDeclaredMember, at: characterIndex, effectiveRange: nil) as? RuntimeMemberReference
    }
}

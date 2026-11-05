import Foundation
import RuntimeViewerCore

/// What a query asks about.
public enum RuntimeCrossReferenceSubject: Hashable, Codable, Sendable {
    /// The function holding an unslid address in an image.
    case function(imagePath: String, address: UInt64)
    case member(RuntimeMemberReference)
    /// Every send of this selector, whatever the receiver. Has callers, no
    /// callees.
    case selector(String)
}

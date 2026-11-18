import Foundation

/// A colour the application layer asks for, described as a value; RuntimeViewerAppUI resolves it
/// (`ColorDescriptor.color`) for the current appearance (proposal `app-core-without-ui-models`).
///
/// Only the colours a view model picks today, and a closed set for the same reason as `IconDescriptor`.
public enum ColorDescriptor: Hashable, Sendable {
    /// The system's secondary label colour.
    case secondaryLabel
    /// The system's tertiary label colour.
    case tertiaryLabel
    /// The colour Xcode gives this kind of file.
    case imageKind(RuntimeImageKind)
}

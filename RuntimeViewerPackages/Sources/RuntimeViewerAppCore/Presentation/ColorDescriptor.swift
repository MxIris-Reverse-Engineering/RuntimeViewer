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
    /// The naming word cloud's colour for a word most representative of this category: the
    /// first, second or third colour of its palette (`NamingWordCategory.paletteIndex`).
    case namingWordCategory(NamingWordCategory)
    /// The naming word cloud's canvas, the background its palette was chosen against.
    case namingWordCloudCanvas
}

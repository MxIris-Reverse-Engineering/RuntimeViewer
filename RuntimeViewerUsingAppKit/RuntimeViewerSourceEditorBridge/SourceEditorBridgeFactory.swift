import AppKit

/// Where the app gets its SourceEditor bridges from.
///
/// Compiled in every build, unlike the bridge itself: in one without the reconstructed SourceEditor
/// frameworks — and in the Intel slice of a universal one, for which they have no slice — this is
/// all the framework holds, `isAvailable` is `false`, and the app shows interfaces in the built-in
/// `NSTextView`.
public enum SourceEditorBridgeFactory {
    /// Whether this build of the framework was compiled with SourceEditor.
    public static var isAvailable: Bool {
        #if canImport(SourceEditor)
        true
        #else
        false
        #endif
    }

    /// A new bridge with its own editor view, or `nil` when the framework was compiled without
    /// SourceEditor.
    public static func makeBridge() -> SourceEditorBridging? {
        #if canImport(SourceEditor)
        SourceEditorBridge()
        #else
        nil
        #endif
    }

    /// One of the `.xccolortheme` files the framework ships in its own resources, such as
    /// `Default (Dark)`, or `nil` when the framework was compiled without SourceEditor.
    public static func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        #if canImport(SourceEditor)
        SourceEditorBridge.builtInThemeDictionary(named: themeName)
        #else
        nil
        #endif
    }
}

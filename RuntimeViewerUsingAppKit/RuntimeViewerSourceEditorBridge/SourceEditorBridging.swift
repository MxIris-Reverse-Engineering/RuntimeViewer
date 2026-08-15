import AppKit

/// The contract between RuntimeViewer and the loadable bundle that drives Xcode's private
/// `SourceEditor` framework.
///
/// **This file is compiled into two targets**: the app and the bundle. It has to be, because
/// the app must not link — directly or transitively — anything that references `SourceEditor`;
/// if it did, an installation without Xcode would fail in dyld before `main` runs. The two
/// sides therefore meet through an `@objc` protocol, which the Objective-C runtime matches by
/// name across the bundle boundary rather than by shared Swift module.
///
/// The consequence worth remembering: **nothing here is checked across the boundary at compile
/// time.** Changing a method changes it for both sides only because both sides compile the same
/// file. Keep it that way — do not fork a second copy.
///
/// The same arrangement is already used for `AppKitPlugin` / `RuntimeViewerCatalystHelperPlugin`.
@objc(RuntimeViewerSourceEditorBridging)
protocol SourceEditorBridging: NSObjectProtocol {
    init()

    /// The editor view, ready to be installed in a view hierarchy.
    var editorView: NSView { get }

    /// Receives the ⌘-click notifications. Held weakly.
    var navigationDelegate: SourceEditorBridgingNavigationDelegate? { get set }

    /// Replaces the displayed source.
    ///
    /// - Parameter languageIdentifier: `"swift"` or `"objc"`. Any other value renders the
    ///   text without syntax highlighting rather than failing.
    func setSource(_ source: String, languageIdentifier: String)

    /// Applies a theme built from `.xccolortheme`-equivalent plist contents. Xcode ships
    /// `Default (Dark).xccolortheme` and `Default (Light).xccolortheme` in the framework's
    /// own resources, which is what `SourceEditorThemeLocating` reaches for.
    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int)

    /// Scrolls so that `characterIndex` — a UTF-16 offset into the source last passed to
    /// `setSource(_:languageIdentifier:)` — is visible.
    func scrollToCharacterIndex(_ characterIndex: Int)
}

/// Told when the user ⌘-clicks a token.
///
/// Resolving that token to a `RuntimeObject` deliberately stays on the app side. The
/// framework's own tokenizer is lexical — it guesses identifier categories from a language
/// specification — whereas RuntimeViewer already knows each identifier's real type from the
/// generator. Handing the range back and resolving it against the semantic map keeps the
/// better answer.
@objc(RuntimeViewerSourceEditorBridgingNavigationDelegate)
protocol SourceEditorBridgingNavigationDelegate: NSObjectProtocol {
    /// - Parameter characterRange: the clicked token's UTF-16 range in the source last passed
    ///   to `setSource(_:languageIdentifier:)`.
    func sourceEditorBridge(_ bridge: SourceEditorBridging, didCommandClickTokenIn characterRange: NSRange)
}

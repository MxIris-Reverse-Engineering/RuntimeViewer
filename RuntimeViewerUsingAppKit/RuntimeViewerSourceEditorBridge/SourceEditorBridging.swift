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

    /// Supplies the icon that leads each of the minimap's hover labels. Held weakly.
    ///
    /// Optional in the sense that labels still appear without one — the bridge itself is what
    /// the framework asks, and it answers nil when there is nobody to forward to — but the
    /// framework's own rule is worth knowing: it builds a label only when it has a provider to
    /// ask, so the bridge registers itself unconditionally rather than only once this is set.
    var minimapLandmarkIconProvider: SourceEditorBridgingMinimapLandmarkIconProvider? { get set }

    /// Replaces the displayed source, together with what each range of it actually is.
    ///
    /// The framework parses plain text, so it cannot tell `NSString` from any other identifier
    /// — nothing in the text says it is a class. RuntimeViewer does know, because the interface
    /// was rendered from runtime metadata, and passing that knowledge in lets the editor's own
    /// parse be corrected rather than having colors painted over a wrong one. That distinction
    /// matters beyond color: token ranges, delimiter matching and structural selection all read
    /// the parse.
    ///
    /// - Parameters:
    ///   - languageIdentifier: `"swift"` or `"objc"`. Any other value renders the text without
    ///     the framework's own parse rather than failing.
    ///   - semanticRanges: UTF-16 ranges into `source`, parallel to `semanticNodeTypeNames`.
    ///   - semanticNodeTypeNames: the framework's node type names, which are also the theme's
    ///     syntax keys — `"xcode.syntax.identifier.class"` and friends. Passed as names rather
    ///     than numbers because the numeric ids are assigned in registration order and are not
    ///     stable between versions.
    ///   - commentDecorations: how to draw the generated comments of `source` as tags and which
    ///     of them collapse, or nil to show the comments as plain text. Passed with the source
    ///     rather than separately because the decorations are columns of this very text: the
    ///     editor must never lay out one text with the other's decorations.
    func setSource(
        _ source: String,
        languageIdentifier: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String],
        commentDecorations: SourceEditorBridgingCommentDecorations?
    )

    /// The colours comment tags are drawn with. Called with the theme, and again whenever it or
    /// the appearance changes; until the first call tags are drawn in fallbacks derived from the
    /// label colours.
    ///
    /// - Parameters:
    ///   - fillColor: behind a ``SourceEditorBridgingCommentTagStyle/standard`` tag.
    ///   - warningFillColor: behind a ``SourceEditorBridgingCommentTagStyle/warning`` tag.
    ///   - noteFillColor: behind a ``SourceEditorBridgingCommentTagStyle/note`` tag.
    ///   - labelColor, valueColor, typeColor, nameColor: the text of the runs of each
    ///     ``SourceEditorBridgingCommentRunStyle``.
    ///   - disclosureColor: the triangles that collapse and expand a row.
    func applyCommentTagColors(
        fillColor: NSColor,
        warningFillColor: NSColor,
        noteFillColor: NSColor,
        labelColor: NSColor,
        valueColor: NSColor,
        typeColor: NSColor,
        nameColor: NSColor,
        disclosureColor: NSColor
    )

    /// The editor view's own background, which is what shows past the end of the document.
    /// Set alongside the theme, whose background key covers the text area.
    func applyBackgroundColor(_ backgroundColor: NSColor)

    /// Turns the editor's optional margins and overlays on or off.
    ///
    /// Passed as one call rather than five properties because it is driven by an observation
    /// of Settings, which re-runs on any change and cannot say which value moved. The bridge
    /// diffs against what it last applied, so calling this with unchanged values does nothing.
    ///
    /// - Parameters:
    ///   - showsLineNumbers: the gutter's line numbers. The gutter itself stays installed
    ///     either way — it is also what draws the active-line emphasis.
    ///   - showsFoldingRibbon: the fold arrows between the gutter and the text. Folding needs
    ///     a language service that can name foldable ranges, which is what the `"swift"` and
    ///     `"objc"` identifiers get; any other language shows a ribbon with nothing in it.
    ///   - showsStickyHeaders: pins the enclosing declarations to the top while scrolling.
    ///   - showsMinimap: the document overview down the right edge. Off by default — it is
    ///     the only one of these that takes width away from the text.
    ///   - showsScopeGuides: the vertical indent guides.
    ///   - showsInvisibles: draws a glyph for every space, tab and line ending.
    ///   - showsMarkSeparators: draws a rule across the text at every `// MARK:` line. Does
    ///     nothing until the interface generator emits them.
    func applyDisplayOptions(
        showsLineNumbers: Bool,
        showsFoldingRibbon: Bool,
        showsStickyHeaders: Bool,
        showsMinimap: Bool,
        showsScopeGuides: Bool,
        showsInvisibles: Bool,
        showsMarkSeparators: Bool
    )

    /// Applies a theme built from `.xccolortheme`-equivalent plist contents. Xcode ships
    /// `Default (Dark).xccolortheme` and `Default (Light).xccolortheme` in the framework's
    /// own resources, which is what `SourceEditorThemeLocating` reaches for.
    ///
    /// - Parameter lineNumberFont: the gutter's font, which the theme dictionary has no key
    ///   for. It is passed separately rather than derived from the dictionary because the app
    ///   already holds the resolved `NSFont`, and re-parsing `"SFMono-Regular - 12.0"` on the
    ///   bridge side would be a second implementation of the framework's own parser.
    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont)

    /// Insets the scrolled content by `topInset` without moving the editor view.
    ///
    /// The content pane deliberately extends under the window's toolbar so text scrolls beneath
    /// it. With `NSTextView` that came for free: the scroll view was the pane's own view, and
    /// AppKit adjusted its content insets from the safe area. Here the scroll view is buried
    /// inside `SourceEditorView`, which switches that adjustment off and drives the insets
    /// itself — so without this the first lines and the sticky header are drawn over the
    /// toolbar instead of under it.
    ///
    /// The find panel is laid out relative to this too, so setting it also keeps ⌘F from
    /// opening flush against the window's top edge.
    ///
    /// - Parameter topInset: the hosting **view controller's** `view.safeAreaInsets.top`, which
    ///   is the height the toolbar overlaps the pane by. Not the editor view's own — that reads
    ///   zero once it is nested a few levels down.
    func applyTopContentInset(_ topInset: CGFloat)

    /// Selects `characterRange` — a UTF-16 range into the source last passed to
    /// `setSource(_:languageIdentifier:semanticRanges:semanticNodeTypeNames:)` — scrolls it to
    /// the middle of the view and flashes the editor's callout over it: what the Find navigator
    /// does with a hit once the interface is on screen.
    func revealCharacterRange(_ characterRange: NSRange)
}

/// Told when the user ⌘-clicks a token, and asked what to offer when they right-click one.
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

    /// The items to put at the top of the contextual menu for the token it was opened on.
    ///
    /// Built app-side rather than described to the bridge, because their targets and actions
    /// live there — the same reason the ⌘-click above hands back a range instead of a
    /// destination. Return an empty array for a token that goes nowhere; the framework's own
    /// items are left alone either way.
    ///
    /// - Parameter characterRange: as above, the token's UTF-16 range in the current source.
    func sourceEditorBridge(_ bridge: SourceEditorBridging, contextualMenuItemsForTokenIn characterRange: NSRange) -> [NSMenuItem]
}

/// Asked for the icon that leads each of the minimap's hover labels — the `[M]` in
/// `[M] -copyWithZone:`.
///
/// The framework asks by its own `LandmarkType`, a resilient enum that cannot cross the bundle
/// boundary, so the bridge folds it into `SourceEditorBridgingLandmarkKind` first. The answer is
/// an `NSImage` rather than the `CGImage` the framework wants, because that is what the app's
/// icon renderer produces and because an image drawn by a handler resolves light and dark at
/// draw time; the bridge rasterises it against the editor's own appearance and screen scale.
@objc(RuntimeViewerSourceEditorBridgingMinimapLandmarkIconProvider)
protocol SourceEditorBridgingMinimapLandmarkIconProvider: NSObjectProtocol {
    /// - Parameter pointSize: the side of the square the icon is laid out in. Draw for that
    ///   size rather than returning a larger image to be scaled down, or the glyph goes soft.
    /// - Returns: nil for a kind that gets no icon; the label then starts at its left edge.
    func sourceEditorBridge(
        _ bridge: SourceEditorBridging,
        minimapIconForLandmarkOfKind kind: SourceEditorBridgingLandmarkKind,
        pointSize: CGFloat
    ) -> NSImage?
}

/// How the generated comments of one source are drawn, as plain columns of that source.
///
/// **Every range is a UTF-16 range into the source it was passed with**, like `semanticRanges`.
/// The arrays are parallel where their names pair up (`tagRanges` with `tagStyles`, and so on);
/// a pair whose counts disagree is ignored whole rather than guessed at.
///
/// What to hide and what to colour is decided app-side, where it can be tested without Xcode's
/// frameworks; the bridge only carries it out. A protocol rather than a class because this file
/// is compiled into both targets, and a class declared here would exist twice in the
/// Objective-C runtime under one name.
@objc(RuntimeViewerSourceEditorBridgingCommentDecorations)
protocol SourceEditorBridgingCommentDecorations: NSObjectProtocol {
    /// One rounded tag behind each range. A range must not cross a line break.
    var tagRanges: [NSValue] { get }

    /// A ``SourceEditorBridgingCommentTagStyle`` raw value per tag.
    var tagStyles: [NSNumber] { get }

    /// Runs of tag text drawn in a colour of their own.
    var runRanges: [NSValue] { get }

    /// A ``SourceEditorBridgingCommentRunStyle`` raw value per run.
    var runStyles: [NSNumber] { get }

    /// Text left out of the rendering — comment markers and punctuation. The text closes up
    /// over it; it is still there for copying and finding.
    var hiddenRanges: [NSValue] { get }

    /// For each row that collapses, where its disclosure triangle is drawn: over the columns of
    /// this range, which should show nothing of their own (indentation, or a tree prefix drawn
    /// with ``SourceEditorBridgingCommentRunStyle/concealed``).
    var collapsibleDisclosureRanges: [NSValue] { get }

    /// For each row that collapses, the text hidden while it is collapsed: from the end of the
    /// row's own line to the end of its last descendant line.
    var collapsibleFoldRanges: [NSValue] { get }

    /// For each row that collapses, whether it starts collapsed the first time a source is shown.
    var collapsibleStartsCollapsed: [NSNumber] { get }
}

/// What a tag's fill says about it.
@objc(RuntimeViewerSourceEditorBridgingCommentTagStyle)
enum SourceEditorBridgingCommentTagStyle: Int {
    /// Addresses, offsets, layouts — the facts most comments state.
    case standard
    /// Something the reader should notice: an offset that could not be worked out, a member
    /// the image does not export, an address that does not resolve.
    case warning
    /// A sentence of explanation rather than a fact.
    case note
}

/// The colour a run of tag text is drawn in.
@objc(RuntimeViewerSourceEditorBridgingCommentRunStyle)
enum SourceEditorBridgingCommentRunStyle: Int {
    /// What a fact is: `Address`, `size`, `getter IMP`.
    case label
    /// The fact itself: `0x135DC`, `16`.
    case value
    /// A type name inside a comment.
    case type
    /// A field or case name inside a comment.
    case name
    /// Kept for its width but not drawn — a tree prefix whose columns hold a disclosure triangle.
    case concealed
}

/// What a landmark is, as far as choosing an icon goes.
///
/// The framework tells a declaration from a definition — `classDecl` against `classDef` — and
/// Xcode draws the two alike, so they are folded here. The kinds that only other languages
/// produce (Markdown headings, CSS rules, and so on) all fold into `other`.
@objc(RuntimeViewerSourceEditorBridgingLandmarkKind)
enum SourceEditorBridgingLandmarkKind: Int {
    case mark
    case file
    case actor
    case `class`
    case `extension`
    case `protocol`
    case method
    case function
    case property
    case `enum`
    case `struct`
    case union
    case typeAlias
    case include
    case define
    case macro
    case other
}

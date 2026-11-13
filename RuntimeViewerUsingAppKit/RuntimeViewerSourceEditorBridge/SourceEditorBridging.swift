import AppKit

/// The surface the app drives SourceEditor through, the public API of this framework.
///
/// The app links this framework and calls it directly; `SourceEditorBridgeFactory` hands out the
/// bridge. `SourceEditorBridge`, the class behind it, is compiled only where the reconstructed
/// SourceEditor frameworks are available — official builds on Apple silicon — and links them
/// directly. This file compiles everywhere, so the app's content view and the code that prepares
/// themes, comment decorations and landmark icons build in every checkout. The `@objc` shapes date
/// from when the bridge was a bundle loaded at run time; nothing is loaded dynamically any more.
@objc(RuntimeViewerSourceEditorBridging)
public protocol SourceEditorBridging: NSObjectProtocol {
    init()

    /// The editor view, ready to be installed in a view hierarchy.
    var editorView: NSView { get }

    /// The scroll view inside `editorView` that the text scrolls in, for the views laid over the
    /// editor's top edge: an editor pane registers its tab bar as a container of this scroll view's
    /// top scroll pocket, so that the text scrolled under the bar shows through it blurred. The
    /// editor builds it once, so it never changes.
    var scrollView: NSScrollView { get }

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
    ///   - restoresScrollPosition: scroll a text shown before back to where the reader left it,
    ///     and any other to the top. Pass `false` when a ``revealCharacterRange(_:)`` is about to
    ///     follow, which then decides alone: the scroll waits for the next layout, which can come
    ///     after the reveal and undo it. Folds come back either way.
    func setSource(
        _ source: String,
        languageIdentifier: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String],
        commentDecorations: SourceEditorBridgingCommentDecorations?,
        restoresScrollPosition: Bool
    )

    /// How comment tags are drawn. Called with the theme, and again whenever it or the
    /// appearance changes; until the first call tags are drawn in fallbacks derived from the
    /// label colours. A change of padding, line spacing or comment font lays the decorated text
    /// out again.
    func applyCommentTagAppearance(_ appearance: SourceEditorBridgingCommentTagAppearance)

    /// The editor view's own background, which is what shows past the end of the document.
    /// Set alongside the theme, whose background key covers the text area.
    func applyBackgroundColor(_ backgroundColor: NSColor)

    /// Turns the editor's optional margins and overlays on or off.
    ///
    /// Passed as one call rather than a property each because it is driven by an observation
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
    ///   - showsInsertionPoint: draws the blinking caret at an empty selection. Off by default —
    ///     the text cannot be edited. The insertion point exists either way; this only decides
    ///     whether it is drawn. A selection is drawn regardless.
    func applyDisplayOptions(
        showsLineNumbers: Bool,
        showsFoldingRibbon: Bool,
        showsStickyHeaders: Bool,
        showsMinimap: Bool,
        showsScopeGuides: Bool,
        showsInvisibles: Bool,
        showsMarkSeparators: Bool,
        showsInsertionPoint: Bool
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

    /// Opens the editor's find bar on `query` and highlights every match, leaving keyboard
    /// focus where it was — what the Find navigator does with a text hit, so the reader sees
    /// the other matches in the interface and can step through them with ⌘G.
    ///
    /// Call it before ``revealCharacterRange(_:)`` for the same hit: opening the bar selects the
    /// match nearest the insertion point, and the reveal then selects the hit itself.
    ///
    /// The query also goes to the system's find pasteboard, as any find bar's does.
    func showFindInterface(query: String, pattern: SourceEditorBridgingFindPattern, isCaseSensitive: Bool)

    /// Shows an expansion the way Xcode shows an expanded macro: each part in a gap the editor
    /// opens above or below the line of the part's anchor, with a read-only editor of its own, the
    /// theme's colours and a dismiss button beside its first line. An attached macro's expansion
    /// goes to several places — after a member, inside the body above its closing brace, after
    /// the type — so it is several parts, and they are one expansion: hiding it, or the dismiss
    /// button of any of its gaps, closes every one.
    ///
    /// The parts keep their text until the expansion is hidden, dismissed, or the next
    /// `setSource` replaces the text they hang in. Showing an identifier that is already shown,
    /// or no part at all, does nothing.
    ///
    /// An expansion can come out of another one: a macro's expansion may attach a macro of its
    /// own — `@Observable` puts `@ObservationTracked` on each property it tracks — and Xcode
    /// expands that one from inside the expanded text. Its parts still hang in the source, at the
    /// declaration the attribute belongs to, and it closes with the expansion it came out of.
    ///
    /// - Parameters:
    ///   - title: what each gap is called — the name at the right of its first line and in the
    ///     editor's accessibility rotor of expanded macros.
    ///   - identifier: names the expansion for ``hideInlineExpansion(identifier:)`` and
    ///     ``isInlineExpansionShown(identifier:)``.
    ///   - parentIdentifier: the expansion whose text this one was expanded from, nil for one of
    ///     the source's own. Hiding or dismissing the parent closes this one too; closing this one
    ///     leaves the parent alone. Nothing is shown while the parent is not.
    func showInlineExpansion(
        _ parts: [SourceEditorBridgingInlineExpansionPart],
        languageIdentifier: String,
        title: String,
        identifier: String,
        parentIdentifier: String?
    )

    /// Closes the expansion shown under `identifier`, every part of it, if there is one.
    func hideInlineExpansion(identifier: String)

    /// Whether an expansion is shown under `identifier`. False again once the reader closed it
    /// with its dismiss button.
    func isInlineExpansionShown(identifier: String) -> Bool
}

/// One gap of an inline expansion: the text it shows and the line it opens at. A class, because
/// `SourceEditorBridging` is an Objective-C protocol and takes only what Objective-C can represent.
@objc(RuntimeViewerSourceEditorBridgingInlineExpansionPart)
public final class SourceEditorBridgingInlineExpansionPart: NSObject {
    /// The part's text, without the indentation of the line it opens at, which the gap adds.
    public let source: String

    /// The semantic runs of `source`, as `setSource` takes them.
    public let semanticRanges: [NSValue]

    /// The node type each run of `semanticRanges` is, as `setSource` takes them.
    public let semanticNodeTypeNames: [String]

    /// A UTF-16 range into the source last passed to `setSource`; the part opens at the line its
    /// end lies on.
    public let anchorRange: NSRange

    /// Which side of that line the part opens on.
    public let placement: SourceEditorBridgingInlineExpansionPlacement

    public init(
        source: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String],
        anchorRange: NSRange,
        placement: SourceEditorBridgingInlineExpansionPlacement
    ) {
        self.source = source
        self.semanticRanges = semanticRanges
        self.semanticNodeTypeNames = semanticNodeTypeNames
        self.anchorRange = anchorRange
        self.placement = placement
        super.init()
    }
}

/// Which side of its anchor's line a part of an inline expansion opens on.
@objc(RuntimeViewerSourceEditorBridgingInlineExpansionPlacement)
public enum SourceEditorBridgingInlineExpansionPlacement: Int {
    /// Between the line and the next: what follows a declaration, or a type's closing brace.
    case belowLine
    /// Between the line and the one before: what a type's body ends with, above its closing brace.
    case aboveLine
}

/// How the find bar matches its query, the choices of its pattern menu.
@objc(RuntimeViewerSourceEditorBridgingFindPattern)
public enum SourceEditorBridgingFindPattern: Int {
    case contains
    /// The query between word boundaries.
    case matchesWord
    /// The query after a word boundary.
    case startsWith
    /// The query before a word boundary.
    case endsWith
    /// The query is an ICU regular expression.
    case regularExpression
}

/// The code folding commands the editor view answers, Xcode's Editor ▸ Code Folding menu.
///
/// They travel up the responder chain like any menu action, and the editor view enables them
/// itself. Nothing conforms to this protocol — the editor view implements the methods without
/// it — and the app, which cannot see the editor's own types, uses it only to name the
/// selectors in its menu.
@objc(RuntimeViewerSourceEditorBridgingCodeFoldingCommands)
public protocol SourceEditorBridgingCodeFoldingCommands {
    /// Folds the structure around the insertion point — where the reader last clicked.
    func fold(_ sender: Any?)
    func unfold(_ sender: Any?)
    func unfoldAll(_ sender: Any?)
    func foldAllComments(_ sender: Any?)
    func unfoldAllComments(_ sender: Any?)
}

/// Told when the user ⌘-clicks a token, and asked what to offer when they right-click one.
///
/// Resolving that token to a `RuntimeObject` deliberately stays on the app side. The
/// framework's own tokenizer is lexical — it guesses identifier categories from a language
/// specification — whereas RuntimeViewer already knows each identifier's real type from the
/// generator. Handing the range back and resolving it against the semantic map keeps the
/// better answer.
@objc(RuntimeViewerSourceEditorBridgingNavigationDelegate)
public protocol SourceEditorBridgingNavigationDelegate: NSObjectProtocol {
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

    /// The items to put at the top of the contextual menu opened on a token of an inline
    /// expansion's text — where Xcode offers Expand Macro on a macro the expansion attaches.
    ///
    /// - Parameters:
    ///   - characterRange: the token's UTF-16 range in that part's `source`.
    ///   - partIndex: the part's index in the array ``SourceEditorBridging/showInlineExpansion(_:languageIdentifier:title:identifier:parentIdentifier:)``
    ///     was given.
    ///   - identifier: the expansion's identifier.
    func sourceEditorBridge(
        _ bridge: SourceEditorBridging,
        contextualMenuItemsForTokenIn characterRange: NSRange,
        inInlineExpansionPartAt partIndex: Int,
        identifier: String
    ) -> [NSMenuItem]
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
public protocol SourceEditorBridgingMinimapLandmarkIconProvider: NSObjectProtocol {
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
public protocol SourceEditorBridgingCommentDecorations: NSObjectProtocol {
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

/// How comment tags are drawn, worked out by the app from its theme. A protocol for the same
/// reason as ``SourceEditorBridgingCommentDecorations``; the bridge reads it once per call to
/// ``SourceEditorBridging/applyCommentTagAppearance(_:)`` and keeps what it read.
@objc(RuntimeViewerSourceEditorBridgingCommentTagAppearance)
public protocol SourceEditorBridgingCommentTagAppearance: NSObjectProtocol {
    /// Behind a tag of `style`.
    func fillColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor

    /// Around a tag of `style`, inside its edge; nil draws none.
    func strokeColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor?

    /// What a fact is — a ``SourceEditorBridgingCommentRunStyle/label`` run — in a tag of `style`.
    func labelColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor

    /// Which of several facts a tag holds — a ``SourceEditorBridgingCommentRunStyle/key`` run —
    /// in a tag of any style.
    var keyColor: NSColor { get }

    /// The text of the other ``SourceEditorBridgingCommentRunStyle``s.
    var valueColor: NSColor { get }
    var typeColor: NSColor { get }
    var nameColor: NSColor { get }

    /// The triangles that collapse and expand a row.
    var disclosureColor: NSColor { get }

    /// Of a tag's corners; half the tag's height or more draws a capsule.
    var cornerRadius: CGFloat { get }

    /// Of the line around a tag, drawn inside its edge.
    var strokeWidth: CGFloat { get }

    /// Between a tag's text and its edge, on each side.
    var horizontalPadding: CGFloat { get }

    /// How much taller a line that holds tags is than the lines around it, half above its text
    /// and half below, so that the tags on neighbouring lines, and the code next to them, keep
    /// apart. Zero leaves every line as tall as the text makes it.
    var tagLineSpacing: CGFloat { get }

    /// The font the editor draws comments in. A raised line is measured against it: the line is
    /// as tall as this font's text plus ``tagLineSpacing``, and a tag is drawn as tall as the
    /// text, not as the line.
    var commentFont: NSFont { get }
}

/// What a tag says, which picks its colours.
@objc(RuntimeViewerSourceEditorBridgingCommentTagStyle)
public enum SourceEditorBridgingCommentTagStyle: Int, CaseIterable {
    /// Where code is: a member's address, an `IMP`.
    case address
    /// Where something sits in a value or a table: field and ivar offsets, vtable and protocol
    /// witness table slots.
    case offset
    /// How a type is laid out: size and alignment, an enum's cases and tag bytes.
    case layout
    /// What else is known about a declaration: `@synthesize`, `@dynamic`, a default
    /// implementation, where a private declaration comes from.
    case declaration
    /// Something the reader should notice: an offset that could not be worked out, a member
    /// the image does not export, an address that does not resolve.
    case warning
    /// A sentence of explanation rather than a fact.
    case note
}

/// The colour a run of tag text is drawn in.
@objc(RuntimeViewerSourceEditorBridgingCommentRunStyle)
public enum SourceEditorBridgingCommentRunStyle: Int {
    /// What a fact is: `Address`, `Type Layout`, `getter IMP`.
    case label
    /// The fact itself: `0x135DC`, `16`.
    case value
    /// A type name inside a comment.
    case type
    /// A field or case name inside a comment.
    case name
    /// Kept for its width but not drawn — a tree prefix whose columns hold a disclosure triangle.
    case concealed
    /// Which of several facts this is: the `size` and `stride` of a type layout.
    case key
}

/// What a landmark is, as far as choosing an icon goes.
///
/// The framework tells a declaration from a definition — `classDecl` against `classDef` — and
/// Xcode draws the two alike, so they are folded here. The kinds that only other languages
/// produce (Markdown headings, CSS rules, and so on) all fold into `other`.
@objc(RuntimeViewerSourceEditorBridgingLandmarkKind)
public enum SourceEditorBridgingLandmarkKind: Int {
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

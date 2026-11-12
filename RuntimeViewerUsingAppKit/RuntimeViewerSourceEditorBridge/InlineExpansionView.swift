// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// like the rest of the bridge (see SourceEditorBridge.swift).
#if arch(arm64) && canImport(SourceEditor)

import AppKit
internal import SourceEditor
internal import SourceModelSupport

/// What an inline expansion's gap shows: the expansion's text in a read-only editor of its own,
/// with its title at the right of the first line.
///
/// It is Xcode 26.6's `GapEmbeddedEditorContentView` (IDESourceEditor, 17F113) rebuilt on the
/// reconstruction's public API, as the SourceEditor example app's `InlineDefinitionView` is; the
/// addresses and formulas are in `/Volumes/RE/Xcode/26.6/README.md`, "Macro expansion shown
/// inline". SourceEditor's own `SourceEditorGapEmbeddedEditor` answers neither
/// `layoutInfoForDismissButton(_:size:)` nor `presentationAnimationDuration`, so its gap would show
/// no dismiss button and would not fold open.
///
/// Two things Xcode's view does are left out because nothing here gives them anything to act on:
/// hiding the title when the first line carries a line annotation, and drawing the dismiss button
/// white over a gutter annotation such as a breakpoint.
///
/// One thing is done differently: where the text starts. Xcode pads the embedded editor's text by
/// half the font's point size plus the indent, which lines it up with the host's only while the two
/// editors' left margins match. Here they do not: a gutter is as wide as its widest line number,
/// the host has the folding ribbon, and SourceEditor pads the host's text by half a point size only
/// while its gutter shows certain annotations. So the padding is measured (`alignTextWithHost()`).
final class InlineExpansionView: NSView {
    let embeddedEditorView: SourceEditorView
    /// The editor whose gap this view is in.
    private unowned let hostEditorView: SourceEditorView
    private let embeddedGutter = SourceEditorGutter()
    /// Colours the expansion the way the content pane is coloured: `setSource` installs one of
    /// these on the main editor's language service, and this one is the expansion's.
    private let semanticNodeTypeAdjuster = SemanticNodeTypeAdjuster()
    private let firstLineNumberAttributesProvider = FirstLineNumberAttributesProvider()
    private let firstLineLayoutObserver = FirstLineLayoutObserver()
    private let expansionTitle: String
    /// Columns past the host's column 0 the text starts at.
    private let indent: Int
    private var showsLineNumbers = true
    private var cachedAccessoryColor: (appearance: NSAppearance, color: NSColor)?
    private lazy var titleLabel = NSTextField(labelWithString: expansionTitle)

    /// The expansions shown in `editor`'s gaps.
    static func views(in editor: SourceEditorView) -> [InlineExpansionView] {
        editor.editorGapController.allGapItems.compactMap { $0.contentView as? InlineExpansionView }
    }

    /// - Parameters:
    ///   - indent: columns to shift the text right by; see `SourceEditorBridge.inlineExpansionIndent(for:position:in:)`.
    ///   - anchorLine: the host's line the gap opens at, above or below it, zero-based, for the
    ///     accessibility label.
    init(source: String, language: (any SourceEditorLanguage)?, semanticRanges: [NSRange],
        semanticNodeTypeNames: [String], title: String, indent: Int, anchorLine: Int,
        hostEditorView: SourceEditorView) {
        self.hostEditorView = hostEditorView
        expansionTitle = title
        self.indent = indent
        let editor = InlineExpansionEditorView(frame: .zero, sourceEditorScrollViewClass: SourceEditorScrollView.self)
        editor.initialIndent = indent
        embeddedEditorView = editor
        super.init(frame: .zero)

        semanticNodeTypeAdjuster.load(semanticRanges: semanticRanges, nodeTypeNames: semanticNodeTypeNames)
        // The text as it comes: a document gets a line ending appended at its end, which here
        // would show as an empty last line. The framework's own embedded editors and its Go To
        // preview make the same setting, the preview before it builds the data source as here.
        var formattingOptions = SourceEditorFormattingOptions()
        formattingOptions.lineEndingAtEndOfFileBehavior = .optional
        let dataSource = SourceEditorDataSource(usingMutableString: NSMutableString(string: source),
            language: language, formattingOptions: formattingOptions)
        // As in `setSource`: reading `languageService` creates it, and the adjuster goes in before
        // anything asks the data source to parse.
        if let languageService = dataSource.languageService as? SourceModelLanguageService {
            languageService.nodeTypeAdjuster = semanticNodeTypeAdjuster
        }
        editor.dataSource = dataSource
        // Read-only, as Xcode makes an expanded macro's editor (MacroSourceCodeEditor.makeSourceEditorView,
        // 0x183D84); the caret stays hidden, like the content pane's by default.
        editor.isEditingEnabled = false
        editor.hideCursorWhenEditingDisabled = true
        editor.forceAutomaticallyCheckSpellingWhileTyping = false
        // Xcode keeps the line numbers but leaves out the active-line highlight in an expansion.
        embeddedGutter.emphasizeActiveLines = false
        editor.gutter = embeddedGutter
        // The first line's number is drawn clear, and the gap's dismiss button takes its place.
        embeddedGutter.addLineNumberAttributesProvider(firstLineNumberAttributesProvider)
        firstLineLayoutObserver.inlineExpansionView = self
        editor.layoutManager.addLayoutVisualization(firstLineLayoutObserver)
        // Held weakly by the editor; this view owns the editor.
        editor.delegate = self
        editor.setAccessibilityLabel("Expanded Macro for \"\(title)\" on line \(anchorLine + 1)")
        // The title first and the editor over it, in Xcode's order; the title hides while the
        // first line's text reaches under it.
        addSubview(titleLabel)
        addSubview(editor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InlineExpansionView is created in code")
    }

    override var isFlipped: Bool { true }

    /// Applies the content pane's theme and line number font.
    func apply(_ theme: SourceEditorTheme, lineNumberFont: NSFont) {
        embeddedEditorView.setTheme(theme)
        // As in the content pane: the gutter sizes and draws its numbers with this font, and
        // starts with none. Turning the numbers on again redraws them.
        embeddedGutter.lineNumberFont = lineNumberFont
        if showsLineNumbers {
            embeddedGutter.enableLineNumbers()
        }
        needsLayout = true
    }

    /// Follows the content pane's line numbers, as an expanded macro does in Xcode. Both gutters
    /// change width, so the text is aligned again.
    func setShowsLineNumbers(_ shows: Bool) {
        showsLineNumbers = shows
        if shows {
            embeddedGutter.enableLineNumbers()
        } else {
            embeddedGutter.disableLineNumbers()
        }
        needsLayout = true
    }

    /// Puts the expansion's column 0 where the host's is, then the indent's columns further: the
    /// distance between where the two editors start their text, in window coordinates, without the
    /// padding this editor has now. Each editor lays its lines out from the left edge of its
    /// `layoutBounds`, past its margin accessories, content margin and padding. A no-op once
    /// aligned, so the layouts it starts end.
    fileprivate func alignTextWithHost() {
        let embeddedContentView = embeddedEditorView.contentView
        let hostContentView = hostEditorView.contentView
        let hostTextStart = hostContentView.convert(CGPoint(x: hostContentView.layoutBounds.minX, y: 0), to: nil).x
        let currentPadding = embeddedContentView.additionalLeftPadding
        let unpaddedTextStart = embeddedContentView.convert(CGPoint(x: embeddedContentView.layoutBounds.minX, y: 0), to: nil).x
            - currentPadding
        let indentWidth = embeddedEditorView.layoutManager.spaceWidth * CGFloat(indent)
        let padding = max(0, (hostTextStart - unpaddedTextStart + indentWidth).rounded())
        guard padding != currentPadding else { return }
        embeddedContentView.additionalLeftPadding = padding
        embeddedEditorView.layoutManager.setNeedsLayout()
    }

    /// `GapEmbeddedEditorContentView.layout()` (0x151BD0): the editor starts a quarter line
    /// spacing below the line spacing the gap adds above it and keeps the view's full height; the
    /// title sits at the right of the first line.
    override func layout() {
        super.layout()
        let layoutManager = embeddedEditorView.layoutManager
        embeddedEditorView.frame = CGRect(x: 0, y: layoutManager.lineSpacing * 1.25, width: bounds.width,
            height: bounds.height).integral
        alignTextWithHost()
        titleLabel.font = .systemFont(ofSize: embeddedEditorView.fontTheme.plainTextFont.pointSize)
        titleLabel.textColor = accessoryColor
        titleLabel.appearance = NSAppearance(named: embeddedEditorView.colorTheme.hasLightBackground ? .aqua : .darkAqua)
        titleLabel.sizeToFit()
        titleLabel.alignment = .right
        let titleSize = titleLabel.frame.size
        titleLabel.frame = CGRect(x: bounds.width - titleSize.width - 8,
            y: layoutManager.lineSpacing + layoutManager.defaultLineHeight * 0.5 - titleSize.height * 0.5,
            width: titleSize.width, height: titleSize.height)
    }

    /// `GapEmbeddedEditorContentView.LayoutObserver` (0x153480): after the first line is laid
    /// out, the title hides if the line's text reaches under it.
    fileprivate func updateTitleVisibility() {
        guard let firstLineFrame = embeddedEditorView.layoutManager.layoutFrameForFirstFragmentOfVisibleLine(0,
            includeLineSpacing: false) else {
            titleLabel.isHidden = false
            return
        }
        let firstLineFrameInWindow = embeddedEditorView.contentView.convert(firstLineFrame, to: nil)
        titleLabel.isHidden = firstLineFrameInWindow.intersects(convert(titleLabel.frame, to: nil))
    }

    /// The colour of the title and of the dismiss button: the tertiary label colour as the
    /// theme's appearance resolves it, kept until the appearance changes (`accessoryColor`,
    /// 0x151558).
    private var accessoryColor: NSColor {
        let appearance = embeddedEditorView.colorTheme.nsAppearanceToUse
        if let cachedAccessoryColor, cachedAccessoryColor.appearance == appearance {
            return cachedAccessoryColor.color
        }
        var resolvedColor = NSColor.tertiaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor(cgColor: NSColor.tertiaryLabelColor.cgColor) ?? .tertiaryLabelColor
        }
        cachedAccessoryColor = (appearance, resolvedColor)
        needsLayout = true
        return resolvedColor
    }

    /// The width of the host editor's left margin accessories that come before its gutter
    /// (closure #1 of `layoutInfoForDismissButton(_:size:)`, 0x151308).
    private var hostMarginWidthBeforeGutter: CGFloat {
        var width: CGFloat = 0
        for accessory in hostEditorView.layoutManager.marginAccessories where accessory.marginAnchor == .left {
            if accessory is SourceEditorGutter {
                break
            }
            width += accessory.marginWidth
        }
        return width
    }
}

// MARK: - SourceEditorGapContentView

extension InlineExpansionView: SourceEditorGapContentView {
    /// The gap leaves the editor no content margin above or below its text
    /// (`prepareForEditorGap()`, 0x150C88).
    func prepareForEditorGap() {
        embeddedEditorView.contentView.contentMargins.top = 0
        embeddedEditorView.contentView.contentMargins.bottom = 0
    }

    /// The gap folds open in 0.3 seconds, or 0.5 above ten lines
    /// (`presentationAnimationDuration`, 0x150E5C).
    var presentationAnimationDuration: Double? {
        embeddedEditorView.dataSource.lineCount <= 10 ? 0.3 : 0.5
    }

    /// Read by the editor's accessibility rotor of expanded macros, which lists the gaps of
    /// `editorGapController`.
    var title: String { expansionTitle }

    /// The gap's dismiss button goes into this editor's gutter: right-aligned with the first
    /// line's number, or centred in the gutter while there are no numbers, and centred on the
    /// first line (`layoutInfoForDismissButton(_:size:)`, 0x150F24). The position is in the
    /// coordinates of the button's superview, the gap view.
    func layoutInfoForDismissButton(_ button: NSButton, size: CGSize) -> (position: CGPoint, color: NSColor)? {
        guard let gapView = button.superview, let gutterView = embeddedGutter.marginContentView,
            let firstLineFrame = embeddedEditorView.layoutManager.layoutFrameForFirstFragmentOfVisibleLine(0,
                includeLineSpacing: false) else { return nil }
        let horizontalPosition: CGFloat
        if let numberFrame = embeddedGutter.layerFrameForLineNumber(0) {
            horizontalPosition = gapView.convert(gutterView.convert(numberFrame, to: nil), from: nil).maxX - size.width
        } else {
            horizontalPosition = hostMarginWidthBeforeGutter + embeddedGutter.marginWidth * 0.5 - size.width * 0.5
        }
        let lineSpacing = embeddedEditorView.layoutManager.lineSpacing
        let verticalPosition = (lineSpacing * 2 + firstLineFrame.height + 2) * 0.5 - size.height * 0.5
        return (CGPoint(x: horizontalPosition.rounded(.down), y: verticalPosition.rounded(.down)), accessoryColor)
    }
}

// MARK: - SourceEditorSizableAssociatedView

extension InlineExpansionView: SourceEditorSizableAssociatedView {
    /// As tall as the editor's text plus twice the line spacing, at least two points more
    /// (`preferredSize(constrainedBy:)`, 0x152360). The editor is laid out at the new width first,
    /// since its content size depends on it.
    func preferredSize(constrainedBy size: CGSize) -> CGSize {
        let width = size.width.rounded(.up)
        var editorFrame = embeddedEditorView.frame
        editorFrame.size.width = width
        embeddedEditorView.frame = editorFrame
        let layoutManager = embeddedEditorView.layoutManager
        layoutManager.layoutContentView(embeddedEditorView.contentView)
        let height = max(layoutManager.lineSpacing * 2, 2) + embeddedEditorView.contentSize
        return CGSize(width: width, height: max(min(height, size.height), 0).rounded(.up))
    }
}

// MARK: - SourceEditorGapWithEmbeddedSourceEditor

/// Lets the host editor's accessibility reach the expansion's text.
extension InlineExpansionView: SourceEditorGapWithEmbeddedSourceEditor {}

// MARK: - SourceEditorViewDelegate

extension InlineExpansionView: SourceEditorViewDelegate {
    /// The expansion's editor changed height, so the gap is measured again
    /// (`MacroSourceCodeEditor.sourceEditorView(_:contentSizeDidChange:)`, 0x183FD8).
    func sourceEditorView(_ editor: SourceEditorView, contentSizeDidChange contentSize: CGFloat) {
        hostEditorView.layoutManager.setNeedsLayout()
    }
}

// MARK: - The embedded editor

/// The editor inside an inline expansion, as Xcode's `GapEmbeddedSourceEditorView` is for an
/// expanded macro: as tall as its text, so it neither scrolls nor bounces and passes the scroll
/// wheel on; no background of its own, so the gap's tint shows; the text indented to where the gap
/// opened.
private final class InlineExpansionEditorView: SourceEditorView {
    /// Columns the text is indented by.
    var initialIndent = 0

    /// `GapEmbeddedSourceEditorView.commonInit()` (0x154384).
    override init(frame frameRect: CGRect, sourceEditorScrollViewClass: SourceEditorScrollView.Type) {
        super.init(frame: frameRect, sourceEditorScrollViewClass: sourceEditorScrollViewClass)
        scrollView.dvt_setAutoforwardsScrollWheelEvents(true)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller = nil
        scrollView.horizontalScroller = nil
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InlineExpansionEditorView is created in code")
    }

    /// The gap draws the tint behind the text (`wantsBackgroundColorFromTheme`, 0x17D60).
    override var wantsBackgroundColorFromTheme: Bool { false }

    /// Every theme is wrapped on its way in, as Xcode's setter does (0x154F00).
    override var colorTheme: any SourceEditorColorTheme {
        get { super.colorTheme }
        set { super.colorTheme = InlineExpansionColorTheme(parentColorTheme: newValue) }
    }

    /// The text is indented after every font change (`fontTheme`'s setter, 0x154850), as a start:
    /// `InlineExpansionView.alignTextWithHost()` measures the padding that lines it up.
    override var fontTheme: any SourceEditorFontTheme {
        get { super.fontTheme }
        set {
            super.fontTheme = newValue
            contentView.additionalLeftPadding = (newValue.plainTextFont.pointSize * 0.5
                + layoutManager.spaceWidth * CGFloat(initialIndent)).rounded()
        }
    }
}

/// The theme the editor inside an inline expansion draws with: Xcode's `GapEditorColorTheme`
/// around its `MacroSourceEditorColorTheme` around the content pane's theme. The text, selection
/// and current-line colours stay the theme's; an inactive selection is clear and the insertion
/// point takes the current-line highlight colour (0x1853C0, 0x1853EC); everything else is
/// SourceEditor's default, which the wrappers do not pass on.
private struct InlineExpansionColorTheme: SourceEditorColorTheme {
    let parentColorTheme: any SourceEditorColorTheme

    var backgroundColor: NSColor { parentColorTheme.backgroundColor }
    var selectionColor: NSColor { parentColorTheme.selectionColor }
    var inactiveSelectionColor: NSColor { NSColor(calibratedWhite: 0, alpha: 0) }
    var currentLineHighlightColor: NSColor { parentColorTheme.currentLineHighlightColor }
    var cursorColor: NSColor { parentColorTheme.currentLineHighlightColor }
    var invisiblesColor: NSColor { parentColorTheme.invisiblesColor }
    var plainTextColor: NSColor { parentColorTheme.plainTextColor }

    func color(for token: SourceEditorTokenType) -> NSColor? {
        parentColorTheme.color(for: token)
    }
}

/// Draws the first line's number clear, leaving its place to the dismiss button
/// (`GapEmbeddedEditorContentView.AttributesProvider`, 0x153278, at high priority, 0x153370).
private final class FirstLineNumberAttributesProvider: LineNumberAttributesProvider {
    var priority: LayoutOverrideProviderPriority { .high }

    func lineNumberAttributesForLine(_ line: Int, withIdentifier identifier: SourceEditorLineIdentifier,
        layoutManager: SourceEditorLayoutManager) -> [NSAttributedString.Key: Any]? {
        line == 0 ? [.foregroundColor: NSColor.clear] : nil
    }
}

/// Tells the view when the editor has laid out its first line
/// (`GapEmbeddedEditorContentView.LayoutObserver`).
private final class FirstLineLayoutObserver: LayoutVisualization {
    weak var inlineExpansionView: InlineExpansionView?

    func didLayoutLineLayer(_ lineLayer: SourceEditorLineLayer, forLine line: Int, in contentView: SourceEditorContentView,
        frameChanged: Bool) {
        guard line == 0 else { return }
        inlineExpansionView?.updateTitleVisibility()
        // The editor's own margins are known once it has laid out.
        inlineExpansionView?.alignTextWithHost()
    }
}

#endif

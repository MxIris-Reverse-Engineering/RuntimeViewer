// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them. macOS only: it drives the AppKit
// build of the frameworks; on iOS the bridge is UIKitSourceEditorBridge.
#if os(macOS) && arch(arm64) && canImport(SourceEditor)

import AppKit
import CoreText
import QuartzCore
internal import SourceEditor

/// Draws the line-end tags — tags a space past the end of a line that the reader can click — and
/// reports their clicks.
///
/// A tag looks like a comment tag of a note, with the comment tags' own appearance: a capsule in a
/// note's fill, and in it a label in a note's label colour and a value in the colour of its style,
/// in the comment font. Unlike a comment tag it holds no text of the source — the editor draws a
/// comment tag's text itself, and past the end of a line there is none — so it draws its text in a
/// text layer of its own, and nothing in the source changes: copying, finding and the columns the
/// editor lays out are as they were.
///
/// Its layers go in the content view's underlay, as the comment tags' do, and are placed in each
/// layout pass from the rects a selection of the tag's line would be drawn with, which already
/// account for wrapping and for the columns the comment decorations hide.
///
/// Over a tag the pointer is a pointing hand (a cursor rect of the editor view), the capsule takes a
/// stronger fill and the content view's tool tip is the tag's; a left click without ⌘ or ⌃ is the
/// tag's and goes no further, its mouse-up included. The editor hands every mouse event to its event
/// consumers before acting on it, the moves its tracking area reports while the window is key
/// included (`SourceEditorView+EventHandling.swift` and `SourceEditorView.swift` at the pinned tag).
final class LineEndTagController {
    /// How far a capsule stays inside the height of its text, as a comment tag does.
    private static let verticalInset: CGFloat = 1

    /// How much stronger a capsule's fill is while the pointer is over it.
    private static let hoveredFillAlphaFactor: CGFloat = 2

    /// Told the identifier of a clicked tag.
    var clickHandler: ((String) -> Void)?

    private weak var sourceEditorView: SourceEditorView?

    private var tags: [Tag] = []

    private var tagAppearance = CommentDecorationController.TagAppearance.fallback

    private var capsuleLayers: [CAShapeLayer] = []

    private var textLayers: [CATextLayer] = []

    /// Where the tags were drawn in the last pass, in the content view's coordinates.
    private var targets: [Target] = [] {
        didSet {
            // The pointing hand over each tag has to follow it (see `cursorRectsForContentRect`).
            if targets.map(\.frame) != oldValue.map(\.frame) {
                sourceEditorView?.invalidateCursorRects()
            }
        }
    }

    /// The tag under the pointer, an index into `tags`.
    private var hoveredTagIndex: Int?

    /// Set by a mouse-down on a tag, so that the mouse-up of that click is the tag's too.
    private var consumesNextMouseUp = false

    private var scrollObserver: NSObjectProtocol?

    init(sourceEditorView: SourceEditorView) {
        self.sourceEditorView = sourceEditorView
        // The pointing hands are cursor rects of the editor view, which stays put while the text
        // scrolls under it; nothing else moves them along.
        let clipView = sourceEditorView.scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
            guard let self, !targets.isEmpty else { return }
            self.sourceEditorView?.invalidateCursorRects()
        }
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    // MARK: - Loading

    /// Forgets the tags. Called before the editor takes another text, whose lines the tags were
    /// not placed on.
    func clear() {
        tags = []
        consumesNextMouseUp = false
        setHoveredTagIndex(nil)
        targets = []
        hideLayers(from: 0)
    }

    /// Replaces the tags with `bridgingTags`, whose ranges are UTF-16 ranges into the editor's
    /// current text. A range outside it is left out.
    func show(_ bridgingTags: [SourceEditorBridgingLineEndTag]) {
        setHoveredTagIndex(nil)
        guard let sourceEditorView else { return }
        let dataSource = sourceEditorView.dataSource
        tags = bridgingTags.compactMap { bridgingTag in
            guard bridgingTag.characterRange.location >= 0 else { return nil }
            // The conversion `revealCharacterRange(_:)` makes.
            let line = dataSource.positionFromInternalCharOffset(bridgingTag.characterRange.location, lineHint: 0).line
            guard (0 ..< dataSource.lineCount).contains(line) else { return nil }
            return Tag(
                line: line,
                label: bridgingTag.label,
                value: bridgingTag.value,
                valueStyle: bridgingTag.valueStyle,
                toolTip: bridgingTag.toolTip,
                identifier: bridgingTag.identifier
            )
        }
        // A text already laid out gets no other pass to draw them in; one that is not yet draws
        // nothing now and the tags in its first pass.
        drawTags(in: sourceEditorView.contentView)
    }

    func applyTagAppearance(_ newTagAppearance: CommentDecorationController.TagAppearance) {
        tagAppearance = newTagAppearance
        guard let sourceEditorView, !tags.isEmpty else { return }
        drawTags(in: sourceEditorView.contentView)
    }

    // MARK: - Drawing

    private func drawTags(in contentView: SourceEditorContentView) {
        guard let sourceEditorView, !tags.isEmpty else {
            targets = []
            hideLayers(from: 0)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let underlayLayer = contentView.underlayLayer
        let effectiveAppearance = sourceEditorView.effectiveAppearance
        let tagAppearance = tagAppearance
        let dataSource = sourceEditorView.dataSource
        let fontMetrics = FontMetrics(font: tagAppearance.commentFont)
        let contentsScale = sourceEditorView.window?.backingScaleFactor ?? 2
        var drawnCount = 0
        var newTargets: [Target] = []

        for (tagIndex, tag) in tags.enumerated() {
            guard tag.line < dataSource.lineCount else { continue }
            // A line folded into the one above it is not on screen.
            if tag.line > 0, sourceEditorView.foldingController.foldedRange(enclosing: SourceEditorPosition(line: tag.line, col: 0)) != nil {
                continue
            }
            let lineLength = dataSource.lineContentLengthForLine(tag.line)
            guard lineLength > 0, let lineEndRect = Self.lastDrawnRect(ofLine: tag.line, length: lineLength, in: contentView) else { continue }

            let text = Self.attributedText(of: tag, tagAppearance: tagAppearance, in: effectiveAppearance)
            let textWidth = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)))
            let capsuleHeight = max(min(lineEndRect.height, tagAppearance.lineRaise?.textHeight ?? fontMetrics.textHeight) - 2 * Self.verticalInset, 0)
            let capsuleFrame = CGRect(
                x: lineEndRect.maxX + fontMetrics.spaceWidth,
                y: lineEndRect.midY - capsuleHeight / 2,
                width: textWidth + 2 * tagAppearance.horizontalPadding,
                height: capsuleHeight
            )

            let capsuleLayer = Self.layer(at: drawnCount, in: &capsuleLayers, under: underlayLayer, making: CAShapeLayer.init)
            capsuleLayer.frame = capsuleFrame
            // A stroke is centred on the path, so the path runs half a stroke inside the frame.
            let strokeColor = tagAppearance.stroke(for: .note)
            let strokeInset = strokeColor == nil ? 0 : tagAppearance.strokeWidth / 2
            let pathRect = CGRect(origin: .zero, size: capsuleFrame.size).insetBy(dx: strokeInset, dy: strokeInset)
            let radius = max(min(tagAppearance.cornerRadius - strokeInset, pathRect.height / 2, pathRect.width / 2), 0)
            capsuleLayer.path = CGPath(roundedRect: pathRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            capsuleLayer.fillColor = fillColor(isHovered: tagIndex == hoveredTagIndex, in: effectiveAppearance)
            capsuleLayer.strokeColor = strokeColor.map { CommentDecorationController.cgColor($0, in: effectiveAppearance) }
            capsuleLayer.lineWidth = strokeColor == nil ? 0 : tagAppearance.strokeWidth
            capsuleLayer.isHidden = false

            let textLayer = Self.layer(at: drawnCount, in: &textLayers, under: underlayLayer, making: CATextLayer.init)
            textLayer.contentsScale = contentsScale
            textLayer.string = text
            // Centred on the line as the capsule is, so the text keeps the line's baseline when the
            // comment font is the code's.
            textLayer.frame = CGRect(
                x: capsuleFrame.minX + tagAppearance.horizontalPadding,
                y: lineEndRect.midY - fontMetrics.textHeight / 2,
                width: textWidth,
                height: fontMetrics.textHeight
            )
            textLayer.isHidden = false

            newTargets.append(Target(frame: capsuleFrame, tagIndex: tagIndex, layerIndex: drawnCount))
            drawnCount += 1
        }

        targets = newTargets
        hideLayers(from: drawnCount)
    }

    /// Where the line's last drawn character ends: of the rects a selection of the whole line
    /// would be drawn with, the rightmost on its last row.
    private static func lastDrawnRect(ofLine line: Int, length: Int, in contentView: SourceEditorContentView) -> CGRect? {
        let range = SourceEditorPosition(line: line, col: 0) ..< SourceEditorPosition(line: line, col: length)
        let rects = contentView.selectionRects(for: range, coalesceInteriorRects: false, includeLineSpacing: false)
            .map(\.rect)
            .filter { $0.width > 0 && $0.height > 0 }
        let rowMidYs = rects.map(\.midY)
        guard let lastRowMidY = contentView.isFlipped ? rowMidYs.max() : rowMidYs.min() else { return nil }
        return rects.filter { abs($0.midY - lastRowMidY) < 1 }.max { $0.maxX < $1.maxX }
    }

    /// The label and the value, a space apart, in the comment font and in colours resolved for
    /// `appearance`: CoreText's attributes, which a text layer draws.
    private static func attributedText(
        of tag: Tag,
        tagAppearance: CommentDecorationController.TagAppearance,
        in appearance: NSAppearance
    ) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let labelColor = CommentDecorationController.cgColor(tagAppearance.textColor(for: .label, inTagOf: .note), in: appearance)
        let valueColor = CommentDecorationController.cgColor(tagAppearance.textColor(for: tag.valueStyle, inTagOf: .note), in: appearance)
        let text = NSMutableAttributedString(string: tag.label + " ", attributes: [fontKey: tagAppearance.commentFont, colorKey: labelColor])
        text.append(NSAttributedString(string: tag.value, attributes: [fontKey: tagAppearance.commentFont, colorKey: valueColor]))
        return text
    }

    private func fillColor(isHovered: Bool, in appearance: NSAppearance) -> CGColor {
        let fill = CommentDecorationController.cgColor(tagAppearance.fill(for: .note), in: appearance)
        guard isHovered else { return fill }
        return fill.copy(alpha: min(fill.alpha * Self.hoveredFillAlphaFactor, 1)) ?? fill
    }

    private static func layer<Layer: CALayer>(at index: Int, in layers: inout [Layer], under parent: CALayer, making makeLayer: () -> Layer) -> Layer {
        if index < layers.count {
            let layer = layers[index]
            if layer.superlayer !== parent {
                parent.addSublayer(layer)
            }
            return layer
        }
        let layer = makeLayer()
        parent.addSublayer(layer)
        layers.append(layer)
        return layer
    }

    private func hideLayers(from index: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in capsuleLayers.dropFirst(index) {
            layer.isHidden = true
        }
        for layer in textLayers.dropFirst(index) {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: - Hovering

    private func setHoveredTagIndex(_ tagIndex: Int?) {
        guard tagIndex != hoveredTagIndex else { return }
        hoveredTagIndex = tagIndex
        guard let sourceEditorView else { return }
        let effectiveAppearance = sourceEditorView.effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for target in targets where capsuleLayers.indices.contains(target.layerIndex) {
            capsuleLayers[target.layerIndex].fillColor = fillColor(isHovered: target.tagIndex == tagIndex, in: effectiveAppearance)
        }
        CATransaction.commit()
        // What the gutter does for its annotations: the view's tool tip follows the pointer.
        let toolTip = tagIndex.flatMap { tags.indices.contains($0) ? tags[$0].toolTip : nil }
        if sourceEditorView.contentView.toolTip != toolTip {
            sourceEditorView.contentView.toolTip = toolTip
        }
    }

    private func target(at event: NSEvent, in sourceEditorView: SourceEditorView) -> Target? {
        guard !targets.isEmpty else { return nil }
        let point = sourceEditorView.contentView.convert(event.locationInWindow, from: nil)
        return targets.first { $0.frame.contains(point) }
    }
}

// MARK: - Layout Visualization

extension LineEndTagController: LayoutVisualization {
    func didLayoutInContentView(_ contentView: SourceEditorContentView) {
        drawTags(in: contentView)
    }

    func layoutManagerDidInvalidateAllLayout(_ layoutManager: SourceEditorLayoutManager) {
        targets = []
    }
}

// MARK: - Mouse

extension LineEndTagController: SourceEditorViewEventConsumer {
    var consumerPriority: SourceEditorEventConsumerPriority { .high }

    func handleMouseEvent(_ event: NSEvent, in sourceEditorView: SourceEditorView) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.modifierFlags.isDisjoint(with: [.command, .control]),
                  let target = target(at: event, in: sourceEditorView),
                  tags.indices.contains(target.tagIndex)
            else { return false }
            consumesNextMouseUp = true
            clickHandler?(tags[target.tagIndex].identifier)
            return true
        case .leftMouseUp:
            guard consumesNextMouseUp else { return false }
            consumesNextMouseUp = false
            return true
        case .mouseMoved:
            setHoveredTagIndex(target(at: event, in: sourceEditorView)?.tagIndex)
            return false
        case .mouseExited:
            setHoveredTagIndex(nil)
            return false
        default:
            return false
        }
    }
}

// MARK: - Cursor

extension LineEndTagController: CursorRectOverrideProvider {
    var priority: LayoutOverrideProviderPriority { .medium }

    /// The pointing hand over every tag on screen, which a click acts on. The editor adds these
    /// after its I-beam, in its own coordinates.
    func cursorRectsForContentRect(_ contentRect: CGRect, in sourceEditorView: SourceEditorView) -> [CursorRectOverride] {
        let contentView = sourceEditorView.contentView
        return targets.compactMap { target in
            let rect = sourceEditorView.convert(target.frame, from: contentView).intersection(contentRect)
            return rect.isNull || rect.isEmpty ? nil : CursorRectOverride(cursor: .pointingHand, rect: rect)
        }
    }
}

// MARK: - Values

extension LineEndTagController {
    struct Tag {
        let line: Int
        let label: String
        let value: String
        let valueStyle: SourceEditorBridgingCommentRunStyle
        let toolTip: String?
        let identifier: String
    }

    /// A tag as drawn in a layout pass.
    struct Target {
        /// The capsule, which takes the click, in the content view's coordinates.
        let frame: CGRect
        let tagIndex: Int
        let layerIndex: Int
    }

    /// What a tag's text is measured with.
    struct FontMetrics {
        /// How tall a line of the font is, its ascent plus descent rounded up as the editor rounds
        /// a line's.
        let textHeight: CGFloat

        /// The gap between a line's last character and its tag.
        let spaceWidth: CGFloat

        init(font: NSFont) {
            textHeight = ceil(font.ascender - font.descender)
            let space = NSAttributedString(string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            spaceWidth = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil)))
        }
    }
}

#endif

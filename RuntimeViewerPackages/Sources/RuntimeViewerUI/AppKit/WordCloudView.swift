#if os(macOS)

import AppKit

/// How a word cloud sizes its words: by count alone, so a word's area grows
/// with how often it occurs, in SF Mono, heavier as it grows.
public enum WordCloudTypography {
    public static let maximumFontSize: CGFloat = 120
    public static let minimumFontSize: CGFloat = 12

    /// The most common word at `maximumFontSize`, the rest scaled by the
    /// square root of their share of its count, never below `minimumFontSize`.
    public static func fontSize(count: Int, maximumCount: Int) -> CGFloat {
        guard maximumCount > 0 else { return minimumFontSize }
        let share = CGFloat(max(count, 0)) / CGFloat(maximumCount)
        return max(minimumFontSize, (maximumFontSize * share.squareRoot()).rounded())
    }

    /// Bold from 56 points, semibold from 28, medium from 18, regular below:
    /// a few large words carry the picture and the many small ones stay quiet.
    public static func fontWeight(forSize fontSize: CGFloat) -> NSFont.Weight {
        switch fontSize {
        case 56...: .bold
        case 28...: .semibold
        case 18...: .medium
        default: .regular
        }
    }

    public static func font(ofSize fontSize: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: fontWeight(forSize: fontSize))
    }
}

/// A word cloud on a canvas far larger than a window, as the document view
/// of a scroll view: it draws the words `WordCloudLayout` places, shows which
/// one the pointer is over and which one is selected, reports a click on a
/// word, and pans its scroll view when dragged. A press that moves three
/// points or more is a drag; otherwise it is a click.
///
/// Drawn rather than built of subviews: a cloud runs to a thousand words.
/// The canvas does not depend on the view's size, so resizing the window only
/// shows more or less of the same picture.
public final class WordCloudView: NSView {
    public struct Word: Equatable {
        public let identifier: String
        public let text: String
        public let count: Int
        public let color: NSColor

        public init(identifier: String, text: String, count: Int, color: NSColor) {
            self.identifier = identifier
            self.text = text
            self.count = count
            self.color = color
        }
    }

    /// A word as laid out.
    private struct PlacedWord {
        let word: Word
        let font: NSFont
        let frame: CGRect
    }

    // MARK: - State

    /// The canvas behind the words.
    public var canvasColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    /// The word drawn as selected: its own colour, over a light plate of it
    /// with an outline.
    public var selectedWordIdentifier: String? {
        didSet {
            guard oldValue != selectedWordIdentifier else { return }
            needsDisplay = true
        }
    }

    /// Called with a word's identifier when it is clicked.
    public var wordClickHandler: ((String) -> Void)?

    /// The tooltip of a word, by its identifier.
    public var toolTipProvider: ((String) -> String?)?

    /// Called on the main thread once the words given last are laid out.
    public var layoutCompletionHandler: (() -> Void)?

    /// How many words are drawn, and how many were given.
    public private(set) var placedWordCount = 0
    public private(set) var wordCount = 0

    private var placedWords: [PlacedWord] = []
    private var hoveredWordIdentifier: String? {
        didSet {
            guard oldValue != hoveredWordIdentifier else { return }
            toolTip = hoveredWordIdentifier.flatMap { toolTipProvider?($0) }
            needsDisplay = true
        }
    }

    /// Bumped by every `setWords(_:)`, so a layout that finishes after a
    /// newer one started is dropped.
    private var layoutGeneration = 0

    private var pressLocationInWindow: NSPoint?
    private var isDragging = false

    private static let dragThreshold: CGFloat = 3

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Word cloud")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public override var isOpaque: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - Words

    /// Lays `words` out — the most common first — and draws them once laid
    /// out; returns then. The canvas, and so this view's frame, takes the
    /// size the layout gives it.
    public func setWords(_ words: [Word]) async {
        layoutGeneration += 1
        let generation = layoutGeneration
        let maximumCount = words.map(\.count).max() ?? 0
        let fonts = words.map { WordCloudTypography.font(ofSize: WordCloudTypography.fontSize(count: $0.count, maximumCount: maximumCount)) }
        let sizes = zip(words, fonts).map { word, font in
            let size = (word.text as NSString).size(withAttributes: [.font: font])
            return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }
        let layout = await Task.detached(priority: .userInitiated) {
            WordCloudLayout(wordSizes: sizes)
        }.value
        guard generation == layoutGeneration else { return }
        apply(layout, to: words, fonts: fonts)
    }

    private func apply(_ layout: WordCloudLayout, to words: [Word], fonts: [NSFont]) {
        placedWords = zip(zip(words, fonts), layout.frames).compactMap { wordAndFont, frame in
            frame.map { PlacedWord(word: wordAndFont.0, font: wordAndFont.1, frame: $0) }
        }
        wordCount = words.count
        placedWordCount = placedWords.count
        hoveredWordIdentifier = nil
        setFrameSize(layout.canvasSize)
        needsDisplay = true
        layoutCompletionHandler?()
    }

    /// Where a word is drawn, in this view's coordinates.
    public func frameOfWord(withIdentifier identifier: String) -> CGRect? {
        placedWords.first { $0.word.identifier == identifier }?.frame
    }

    /// The word drawn at `point`, in this view's coordinates.
    public func wordIdentifier(at point: CGPoint) -> String? {
        placedWords.last { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }?.word.identifier
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        canvasColor.setFill()
        dirtyRect.fill()
        for placedWord in placedWords where placedWord.frame.intersects(dirtyRect) {
            draw(placedWord)
        }
    }

    private func draw(_ placedWord: PlacedWord) {
        let identifier = placedWord.word.identifier
        let color = placedWord.word.color
        if identifier == selectedWordIdentifier || identifier == hoveredWordIdentifier {
            let plate = NSBezierPath(roundedRect: placedWord.frame.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4)
            color.withAlphaComponent(identifier == selectedWordIdentifier ? 0.18 : 0.1).setFill()
            plate.fill()
            if identifier == selectedWordIdentifier {
                color.withAlphaComponent(0.7).setStroke()
                plate.lineWidth = 1.5
                plate.stroke()
            }
        }
        (placedWord.word.text as NSString).draw(in: placedWord.frame, withAttributes: [.font: placedWord.font, .foregroundColor: color])
    }

    /// The whole canvas as PNG, its background filled in this view's
    /// appearance, at up to `maximumScale` pixels a point and no more than
    /// `maximumPixelCount` pixels, scaled down in proportion past that.
    public func pngDataOfWholeCanvas(maximumScale: CGFloat = 2, maximumPixelCount: CGFloat = 40_000_000) -> Data? {
        let canvasSize = bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let scale = min(maximumScale, (maximumPixelCount / (canvasSize.width * canvasSize.height)).squareRoot())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width * scale),
            pixelsHigh: Int(canvasSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = canvasSize
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        // Flipped, as the view is, and said so, so that text is drawn the right way up.
        let cgContext = bitmapContext.cgContext
        cgContext.translateBy(x: 0, y: canvasSize.height)
        cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
        let previousSelection = selectedWordIdentifier
        let previousHover = hoveredWordIdentifier
        selectedWordIdentifier = nil
        hoveredWordIdentifier = nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            canvasColor.setFill()
            CGRect(origin: .zero, size: canvasSize).fill()
            placedWords.forEach(draw)
        }
        selectedWordIdentifier = previousSelection
        hoveredWordIdentifier = previousHover
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Pointer

    public override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredWordIdentifier = nil
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseDown(with event: NSEvent) {
        pressLocationInWindow = event.locationInWindow
        isDragging = false
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let pressLocationInWindow else { return }
        if !isDragging {
            let distance = hypot(event.locationInWindow.x - pressLocationInWindow.x, event.locationInWindow.y - pressLocationInWindow.y)
            guard distance >= Self.dragThreshold else { return }
            isDragging = true
            NSCursor.closedHand.set()
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        // The canvas follows the pointer: the visible area moves against it.
        let magnification = enclosingScrollView?.magnification ?? 1
        var origin = clipView.bounds.origin
        origin.x -= event.deltaX / magnification
        origin.y -= event.deltaY / magnification
        clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            pressLocationInWindow = nil
            isDragging = false
            updateCursor(at: convert(event.locationInWindow, from: nil))
        }
        guard !isDragging else { return }
        if let identifier = wordIdentifier(at: convert(event.locationInWindow, from: nil)) {
            wordClickHandler?(identifier)
        }
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredWordIdentifier = wordIdentifier(at: point)
        if !isDragging {
            updateCursor(at: point)
        }
    }

    private func updateCursor(at point: CGPoint) {
        if isDragging {
            NSCursor.closedHand.set()
        } else if wordIdentifier(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }
}

#endif

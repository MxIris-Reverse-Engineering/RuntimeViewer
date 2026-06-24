import AppKit
import RuntimeViewerUI

/// A vertical line-number gutter rendered as an `NSRulerView` for a TextKit 2 `NSTextView`.
///
/// Line numbers are aligned to each paragraph by enumerating the visible `NSTextLayoutFragment`s
/// of the client text view's `NSTextLayoutManager`. A soft-wrapped paragraph spans multiple
/// `NSTextLineFragment`s but shares a single number drawn on its first line fragment, matching
/// Xcode's gutter behaviour.
///
/// The ruler owns everything intrinsic to its own rendering — scroll tracking and reflow tracking
/// are handled internally through clip-view bounds and text-view frame notifications. Content and
/// theme updates are pushed in by the owning view controller via ``reload()`` and ``backgroundColor``.
final class ContentLineNumberRulerView: NSRulerView {
    /// Horizontal padding between the line numbers and the gutter edges.
    private let horizontalPadding: CGFloat = 5

    /// The minimum thickness of the gutter regardless of digit count.
    private let minimumThickness: CGFloat = 32

    /// Width of the trailing separator line.
    private let separatorWidth: CGFloat = 1

    /// Background color of the gutter, kept in sync with the editor background by the controller.
    var backgroundColor: NSColor = .textBackgroundColor {
        didSet {
            guard backgroundColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Color used to draw the line numbers.
    var lineNumberColor: NSColor = NSColor(light: NSColor(white: 0.6, alpha: 1), dark: NSColor(white: 0.46, alpha: 1)) {
        didSet {
            guard lineNumberColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Color of the trailing separator line.
    var separatorColor: NSColor = NSColor(light: NSColor(white: 0.85, alpha: 1), dark: NSColor(white: 0.26, alpha: 1)) {
        didSet {
            guard separatorColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Character offsets where each line begins, used to resolve a fragment's 1-based line number.
    private var lineStartOffsets: [Int] = [0]

    private var textView: NSTextView? { clientView as? NSTextView }

    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Init

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = minimumThickness
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeNotificationObservers()
    }

    // MARK: - Client View

    override var clientView: NSView? {
        didSet {
            guard clientView !== oldValue else { return }
            setupNotificationObservers()
            reload()
        }
    }

    // MARK: - Content

    /// Rebuilds the line-start cache, recomputes the gutter thickness, and requests a redraw.
    ///
    /// The owning controller calls this after replacing the text view's content (which also covers
    /// font-size changes, since those flow through a freshly rendered attributed string).
    func reload() {
        rebuildLineStartOffsets()
        updateThickness()
        needsDisplay = true
    }

    private func rebuildLineStartOffsets() {
        guard let string = textView?.textStorage?.string, !string.isEmpty else {
            lineStartOffsets = [0]
            return
        }
        let text = string as NSString
        let length = text.length
        var offsets: [Int] = [0]
        var searchStart = 0
        while searchStart < length {
            let newlineRange = text.range(of: "\n", options: [], range: NSRange(location: searchStart, length: length - searchStart))
            guard newlineRange.location != NSNotFound else { break }
            let nextLineStart = newlineRange.location + newlineRange.length
            offsets.append(nextLineStart)
            searchStart = nextLineStart
        }
        lineStartOffsets = offsets
    }

    private func updateThickness() {
        let lineCount = max(lineStartOffsets.count, 1)
        let widestNumber = String(repeating: "9", count: String(lineCount).count) as NSString
        let textWidth = widestNumber.size(withAttributes: [.font: lineNumberFont]).width
        let newThickness = max(minimumThickness, ceil(textWidth) + horizontalPadding * 2)
        if abs(newThickness - ruleThickness) > 0.5 {
            ruleThickness = newThickness
        }
    }

    /// The font used for line numbers, derived from the rendered text so it tracks font-size changes.
    private var lineNumberFont: NSFont {
        let defaultSize = NSFont.systemFontSize
        guard let textStorage = textView?.textStorage,
              textStorage.length > 0,
              let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else {
            return .monospacedSystemFont(ofSize: defaultSize, weight: .regular)
        }
        return .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }

    /// Resolves the 1-based line number for a character offset via binary search over the line-start cache.
    private func lineNumber(for offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count - 1
        var result = 0
        while low <= high {
            let middle = (low + high) / 2
            if lineStartOffsets[middle] <= offset {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result + 1
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        drawLineNumbers()
        drawSeparator()
    }

    private func drawLineNumbers() {
        guard let textView,
              let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager
        else { return }

        let font = lineNumberFont
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: lineNumberColor,
        ]

        // `relativePoint` maps the text view's origin into the ruler's (flipped) coordinate space,
        // absorbing the current scroll offset; adding a container-space y yields the ruler y.
        let relativePoint = convert(NSPoint.zero, from: textView)
        let containerOrigin = textView.textContainerOrigin

        let visibleRect = textView.visibleRect
        let visibleMinYInContainer = visibleRect.minY - containerOrigin.y
        let visibleMaxYInContainer = visibleRect.maxY - containerOrigin.y

        let documentStart = textLayoutManager.documentRange.location
        let startLocation = textLayoutManager
            .textLayoutFragment(for: CGPoint(x: 0, y: max(visibleMinYInContainer, 0)))?
            .rangeInElement.location ?? documentStart

        // One layout fragment == one paragraph, so the line number simply increments per fragment.
        // It is resolved once for the first visible fragment, then advanced.
        var currentLineNumber: Int?

        textLayoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout, .ensuresExtraLineFragment]) { [weak self] fragment in
            guard let self else { return false }
            let fragmentFrame = fragment.layoutFragmentFrame
            guard fragmentFrame.minY <= visibleMaxYInContainer else { return false }

            let lineNumber: Int
            if let currentLineNumber {
                lineNumber = currentLineNumber
            } else {
                let offset = textContentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
                lineNumber = self.lineNumber(for: offset)
            }
            currentLineNumber = lineNumber + 1

            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? fragmentFrame.height
            let numberString = NSAttributedString(string: "\(lineNumber)", attributes: numberAttributes)
            let numberSize = numberString.size()
            let drawX = ruleThickness - numberSize.width - horizontalPadding
            let drawY = (relativePoint.y + containerOrigin.y + fragmentFrame.minY + (lineHeight - numberSize.height) / 2).rounded()
            numberString.draw(at: NSPoint(x: drawX, y: drawY))
            return true
        }
    }

    private func drawSeparator() {
        separatorColor.setFill()
        let separatorRect = NSRect(x: bounds.maxX - separatorWidth, y: bounds.minY, width: separatorWidth, height: bounds.height)
        separatorRect.fill()
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        removeNotificationObservers()

        // Redraw in lockstep with scrolling. `queue: nil` keeps the callback synchronous on the
        // posting (main) thread so the numbers never lag a frame behind the text.
        if let contentView = scrollView?.contentView {
            contentView.postsBoundsChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: nil
            ) { [weak self] _ in
                self?.needsDisplay = true
            }
            notificationObservers.append(observer)
        }

        // Redraw when the text reflows (window resize, width-tracking container changes height).
        if let textView {
            textView.postsFrameChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: nil
            ) { [weak self] _ in
                self?.needsDisplay = true
            }
            notificationObservers.append(observer)
        }
    }

    private func removeNotificationObservers() {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }
}

import AppKit
import QuartzCore
import SourceEditor

/// Draws the generated comments as tags and collapses the rows the app marks as collapsible.
///
/// One object answers every question the editor asks about the decorations — which columns are
/// left out, where the text moves to make room for a tag's padding, which runs take which colour
/// — and draws the tags and the disclosure triangles itself, from a single layout visualization.
/// The text is never changed: everything here is laid over it, which is also why copying and
/// finding keep working on the comments as they were printed.
///
/// What each of the framework's hooks does with an answer was settled by
/// `SourceEditorOverlayBehaviorTests`: hidden columns close up, attribute overrides and column
/// shifts both count source columns, and shifts on one line add up.
///
/// **The tables describe one text.** `load(_:source:)` must run only after the data source of
/// that text is in place, and `clear()` before anything lays out the previous text again: a column
/// range past the end of a line is a `fatalError` in the framework, not a no-op.
final class CommentDecorationController {
    /// How far a tag stays inside its line's height, so tags on neighbouring lines do not touch.
    private static let tagVerticalInset: CGFloat = 1

    private weak var sourceEditorView: SourceEditorView?

    /// Guards the two values the layout hooks read, which may run while a line is being built.
    /// Both are replaced whole on the main thread, so a reader always sees one consistent value.
    private let stateLock = NSLock()
    private var unlockedTables = Tables.empty
    private var unlockedTagAppearance = TagAppearance.fallback

    /// What the tables were built from, kept to build them again when the padding changes: the
    /// padding is a column shift, baked into the tables.
    private var loadedDecorations: SourceEditorBridgingCommentDecorations?
    private var loadedSource: String?

    private var tagLayers: [CAShapeLayer] = []

    private var disclosureLayers: [CAShapeLayer] = []

    /// Where the triangles were drawn in the last layout pass, in the content view's coordinates,
    /// with the row each one toggles and the layer in `disclosureLayers` it was drawn with.
    private var disclosureTargets: [DisclosureTarget] = [] {
        didSet {
            // The arrow over each triangle has to follow it (see `cursorRectsForContentRect`).
            if disclosureTargets.map(\.frame) != oldValue.map(\.frame) {
                sourceEditorView?.invalidateCursorRects()
            }
        }
    }

    private var scrollObserver: NSObjectProtocol?

    init(sourceEditorView: SourceEditorView) {
        self.sourceEditorView = sourceEditorView
        // The arrows are cursor rects of the editor view, which stays put while the text
        // scrolls under it; nothing else moves them along.
        let clipView = sourceEditorView.scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
            guard let self, !disclosureTargets.isEmpty else { return }
            self.sourceEditorView?.invalidateCursorRects()
        }
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    private var tables: Tables {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unlockedTables
    }

    private var tagAppearance: TagAppearance {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unlockedTagAppearance
    }

    private func replaceTables(with tables: Tables) {
        stateLock.lock()
        unlockedTables = tables
        stateLock.unlock()
    }

    // MARK: - Loading

    /// Forgets the current decorations. Called before the editor can lay out a different text.
    func clear() {
        loadedDecorations = nil
        loadedSource = nil
        guard !tables.isEmpty else { return }
        replaceTables(with: .empty)
        disclosureTargets = []
        hideLayers(from: 0, in: tagLayers)
        hideLayers(from: 0, in: disclosureLayers)
    }

    /// Takes on the decorations of `source`, which the editor's data source must already hold.
    func load(_ decorations: SourceEditorBridgingCommentDecorations?, source: String) {
        loadedDecorations = decorations
        loadedSource = decorations == nil ? nil : source
        let newTables = decorations.map { Tables(decorations: $0, source: source, tagPadding: tagAppearance.horizontalPadding) } ?? .empty
        replaceTables(with: newTables)
        disclosureTargets = []
        guard let sourceEditorView else { return }
        // The line layers of the new text may already have been built without the decorations.
        sourceEditorView.layoutManager.invalidateAllLayout()
    }

    /// Collapses every row that starts collapsed. For a source shown for the first time; a source
    /// coming back gets the folds it had instead.
    ///
    /// Inner rows are folded before the rows around them: `fold(ranges:)` skips a range an
    /// existing fold already covers (27.2 @ 0xDA140), so folding the outer row first would leave
    /// its descendants expanded behind it.
    func collapseRowsThatStartCollapsed() {
        guard let foldingController = sourceEditorView?.foldingController else { return }
        let rows = tables.rows
        for rowIndex in rows.indices.sorted(by: { rows[$0].foldRange.lowerBound > rows[$1].foldRange.lowerBound }) where rows[rowIndex].startsCollapsed {
            foldingController.fold(rows[rowIndex].foldRange, animate: false, completion: nil)
        }
    }

    // MARK: - Appearance

    func applyTagAppearance(_ newTagAppearance: TagAppearance) {
        let paddingChanged = newTagAppearance.horizontalPadding != tagAppearance.horizontalPadding
        stateLock.lock()
        unlockedTagAppearance = newTagAppearance
        stateLock.unlock()
        if paddingChanged, let loadedDecorations, let loadedSource {
            replaceTables(with: Tables(decorations: loadedDecorations, source: loadedSource, tagPadding: newTagAppearance.horizontalPadding))
            disclosureTargets = []
        }
        guard !tables.isEmpty, let sourceEditorView else { return }
        // Run colours and shifts are asked only while a line layer is built.
        sourceEditorView.layoutManager.invalidateAllLayout()
    }

    // MARK: - Collapsing

    private func isCollapsed(_ row: Row) -> Bool {
        guard let foldingController = sourceEditorView?.foldingController else { return false }
        // The first position after the row's own line: inside the row's fold when it is collapsed,
        // and inside no fold of a descendant, which starts at the end of the descendant's line.
        let firstHiddenPosition = SourceEditorPosition(line: row.line + 1, col: 0)
        return foldingController.foldedRange(enclosing: firstHiddenPosition) == row.foldRange
    }

    private func toggle(rowAt rowIndex: Int, includingDescendants: Bool) {
        guard let foldingController = sourceEditorView?.foldingController else { return }
        let rows = tables.rows
        guard rows.indices.contains(rowIndex) else { return }
        let row = rows[rowIndex]
        let descendants = row.descendantRowIndices.map { rows[$0] }

        if isCollapsed(row) {
            // Expanding one level brings the rows inside back as they were; ⌥ opens them all.
            foldingController.unfold(row.foldRange, restoreNestedFolds: !includingDescendants, animate: false)
            if includingDescendants {
                for descendant in descendants where isCollapsed(descendant) {
                    foldingController.unfold(descendant.foldRange, restoreNestedFolds: false, animate: false)
                }
            }
        } else {
            if includingDescendants {
                for descendant in descendants.sorted(by: { $0.foldRange.lowerBound > $1.foldRange.lowerBound }) where !isCollapsed(descendant) {
                    foldingController.fold(descendant.foldRange, animate: false, completion: nil)
                }
            }
            foldingController.fold(row.foldRange, animate: false, completion: nil)
        }
    }

    // MARK: - Drawing

    private func drawDecorations(in contentView: SourceEditorContentView) {
        let tables = tables
        let tagAppearance = tagAppearance
        guard !tables.isEmpty,
              let sourceEditorView,
              let visibleRange = sourceEditorView.layoutManager.sourceRangeForVisibleLinesIn(rect: contentView.layoutBounds, inContentView: contentView)
        else {
            disclosureTargets = []
            hideLayers(from: 0, in: tagLayers)
            hideLayers(from: 0, in: disclosureLayers)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let underlayLayer = contentView.underlayLayer
        let effectiveAppearance = sourceEditorView.effectiveAppearance
        var tagCount = 0
        var disclosureCount = 0
        var targets: [DisclosureTarget] = []

        let lastLine = min(visibleRange.upperBound.line, tables.lineCount - 1)
        var line = max(visibleRange.lowerBound.line, 0)
        while line <= lastLine {
            defer { line += 1 }
            // A line folded into the row above it is not on screen; the row's own line is, since
            // its fold starts at the end of it.
            if line > 0, sourceEditorView.foldingController.foldedRange(enclosing: SourceEditorPosition(line: line, col: 0)) != nil {
                continue
            }

            for tag in tables.tagsByLine[line] ?? [] {
                for textFrame in Self.rowFrames(of: tag, onLine: line, in: contentView) {
                    let layer = Self.layer(at: tagCount, in: &tagLayers, under: underlayLayer)
                    tagCount += 1
                    let frame = textFrame.insetBy(dx: -tagAppearance.horizontalPadding, dy: Self.tagVerticalInset)
                    layer.frame = frame
                    // A stroke is centred on the path, so the path runs half a stroke inside the
                    // frame to keep the line within the tag.
                    let strokeColor = tagAppearance.stroke(for: tag.style)
                    let strokeInset = strokeColor == nil ? 0 : tagAppearance.strokeWidth / 2
                    let pathRect = CGRect(origin: .zero, size: frame.size).insetBy(dx: strokeInset, dy: strokeInset)
                    let radius = max(min(tagAppearance.cornerRadius - strokeInset, pathRect.height / 2, pathRect.width / 2), 0)
                    layer.path = CGPath(roundedRect: pathRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    layer.fillColor = Self.cgColor(tagAppearance.fill(for: tag.style), in: effectiveAppearance)
                    layer.strokeColor = strokeColor.map { Self.cgColor($0, in: effectiveAppearance) }
                    layer.lineWidth = strokeColor == nil ? 0 : tagAppearance.strokeWidth
                    layer.isHidden = false
                }
            }

            for rowIndex in tables.rowIndicesByLine[line] ?? [] {
                let row = tables.rows[rowIndex]
                guard let cellFrame = Self.frame(ofColumns: row.disclosureColumns, onLine: line, in: contentView) else { continue }
                let layerIndex = disclosureCount
                let layer = Self.layer(at: layerIndex, in: &disclosureLayers, under: underlayLayer)
                disclosureCount += 1
                let side = min(cellFrame.height * 0.5, max(cellFrame.width - 2, 6))
                // Turned rather than redrawn, so a click can animate the turn. Bounds and
                // position, not frame, which is undefined under a transform.
                layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                layer.position = CGPoint(x: cellFrame.midX, y: cellFrame.midY)
                layer.path = Self.disclosurePath(side: side)
                layer.setAffineTransform(CGAffineTransform(rotationAngle: Self.disclosureAngle(isCollapsed: isCollapsed(row), isFlipped: contentView.isFlipped)))
                layer.fillColor = Self.cgColor(tagAppearance.disclosure, in: effectiveAppearance)
                layer.isHidden = false
                // The whole cell takes the click, not only the triangle's few points.
                targets.append(DisclosureTarget(frame: cellFrame, rowIndex: rowIndex, layerIndex: layerIndex))
            }
        }

        disclosureTargets = targets
        hideLayers(from: tagCount, in: tagLayers)
        hideLayers(from: disclosureCount, in: disclosureLayers)
    }

    /// A tag's extent on screen, one rect per row the editor draws it on, in the content view's
    /// coordinates.
    ///
    /// While the tag stays on one row, the rects a selection of it would be drawn with are the
    /// answer. Once the editor wraps the line inside the tag, a selection reaches the edge of the
    /// view where each row breaks, and one rect around all of it covered the whole line. So each
    /// column is measured on its own instead and the columns are grouped by row, leaving out
    /// spaces, which would otherwise widen a row where it breaks.
    private static func rowFrames(of tag: Tag, onLine line: Int, in contentView: SourceEditorContentView) -> [CGRect] {
        let rects = drawnRects(ofColumns: tag.columns, onLine: line, in: contentView)
        guard let first = rects.first else { return [] }
        if rects.allSatisfy({ abs($0.midY - first.midY) < 1 }) {
            return [rects.dropFirst().reduce(first) { $0.union($1) }]
        }
        var rowFrames: [CGRect] = []
        for column in tag.columns where !tag.spaceColumns.contains(column) {
            guard let rect = drawnRects(ofColumns: column ..< column + 1, onLine: line, in: contentView).first else { continue }
            if let lastFrame = rowFrames.last, abs(lastFrame.midY - rect.midY) < 1 {
                rowFrames[rowFrames.count - 1] = lastFrame.union(rect)
            } else {
                rowFrames.append(rect)
            }
        }
        return rowFrames
    }

    /// The rects a selection of the columns would be drawn with — one per run of drawn columns
    /// on each row — which already account for hidden columns and shifts.
    private static func drawnRects(ofColumns columns: Range<Int>, onLine line: Int, in contentView: SourceEditorContentView) -> [CGRect] {
        let range = SourceEditorPosition(line: line, col: columns.lowerBound) ..< SourceEditorPosition(line: line, col: columns.upperBound)
        return contentView.selectionRects(for: range, coalesceInteriorRects: false, includeLineSpacing: false)
            .map(\.rect)
            .filter { $0.width > 0 && $0.height > 0 }
    }

    /// The columns' extent on screen, in the content view's coordinates — the rects a selection
    /// of them would be drawn with, which already account for hidden columns and shifts.
    private static func frame(ofColumns columns: Range<Int>, onLine line: Int, in contentView: SourceEditorContentView) -> CGRect? {
        guard !columns.isEmpty else { return nil }
        let range = SourceEditorPosition(line: line, col: columns.lowerBound) ..< SourceEditorPosition(line: line, col: columns.upperBound)
        let rects = contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false)
            .map(\.rect)
            .filter { $0.width > 0 && $0.height > 0 }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func layer(at index: Int, in layers: inout [CAShapeLayer], under parent: CALayer) -> CAShapeLayer {
        if index < layers.count {
            let layer = layers[index]
            if layer.superlayer !== parent {
                parent.addSublayer(layer)
            }
            return layer
        }
        let layer = CAShapeLayer()
        parent.addSublayer(layer)
        layers.append(layer)
        return layer
    }

    private func hideLayers(from index: Int, in layers: [CAShapeLayer]) {
        guard index < layers.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers[index...] {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    /// ▸, filling a square of `side` points; `disclosureAngle` turns it to ▾.
    private static func disclosurePath(side: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: side * 0.25, y: 0))
        path.addLine(to: CGPoint(x: side * 0.85, y: side / 2))
        path.addLine(to: CGPoint(x: side * 0.25, y: side))
        path.closeSubpath()
        return path
    }

    /// The turn from ▸ that shows a row's state: none when collapsed, a quarter turn clockwise
    /// when expanded — towards larger y in a flipped view, smaller y otherwise.
    private static func disclosureAngle(isCollapsed: Bool, isFlipped: Bool) -> CGFloat {
        isCollapsed ? 0 : (isFlipped ? .pi / 2 : -.pi / 2)
    }

    // MARK: - Click Feedback

    /// How long a triangle takes to turn, and the press behind it to fade.
    private static let disclosureTurnDuration: CFTimeInterval = 0.18
    private static let disclosurePressFadeDuration: CFTimeInterval = 0.3

    /// Shows a click on a triangle: a round press behind it that fades, and the triangle turning
    /// to its new state. The layout pass the fold sets off draws the same end state again with
    /// actions disabled, which leaves an animation already running alone. The row keeps its
    /// layer through it: a fold only adds or removes rows below the row clicked.
    private func showClick(on target: DisclosureTarget, turningFromCollapsed wasCollapsed: Bool) {
        guard let sourceEditorView, disclosureLayers.indices.contains(target.layerIndex) else { return }
        let contentView = sourceEditorView.contentView
        let disclosureLayer = disclosureLayers[target.layerIndex]
        let tagAppearance = tagAppearance

        let pressLayer = CAShapeLayer()
        let diameter = min(target.frame.height, target.frame.width)
        pressLayer.frame = CGRect(x: target.frame.midX - diameter / 2, y: target.frame.midY - diameter / 2, width: diameter, height: diameter)
        pressLayer.path = CGPath(ellipseIn: pressLayer.bounds, transform: nil)
        pressLayer.fillColor = Self.cgColor(tagAppearance.disclosure.withAlphaComponent(0.22), in: sourceEditorView.effectiveAppearance)
        pressLayer.opacity = 0
        contentView.underlayLayer.insertSublayer(pressLayer, below: disclosureLayer)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            pressLayer.removeFromSuperlayer()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.disclosurePressFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pressLayer.add(fade, forKey: "fade")

        let toAngle = Self.disclosureAngle(isCollapsed: !wasCollapsed, isFlipped: contentView.isFlipped)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = Self.disclosureAngle(isCollapsed: wasCollapsed, isFlipped: contentView.isFlipped)
        turn.toValue = toAngle
        turn.duration = Self.disclosureTurnDuration
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        disclosureLayer.add(turn, forKey: "turn")
        CATransaction.setDisableActions(true)
        disclosureLayer.setAffineTransform(CGAffineTransform(rotationAngle: toAngle))
        CATransaction.commit()
    }

    private static func cgColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

// MARK: - Layout Providers

extension CommentDecorationController: HiddenTextOverrideProvider, ColumnShiftOverrideProvider, TextAttributeOverrideProvider {
    var priority: LayoutOverrideProviderPriority { .medium }

    func visibleColumnRanges(for line: Int, in layoutManager: SourceEditorLayoutManager) -> [Range<Int>]? {
        tables.visibleColumnsByLine[line]
    }

    func hiddenTextRange(enclosing position: SourceEditorPosition, in layoutManager: SourceEditorLayoutManager) -> Range<SourceEditorPosition>? {
        nil
    }

    func columnShiftEffectsForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [Int: CGFloat] {
        tables.shiftsByLine[line] ?? [:]
    }

    func textAttributeOverridesForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [SourceEditorTextAttributeOverride] {
        guard let runs = tables.runsByLine[line] else { return [] }
        let tagAppearance = tagAppearance
        return runs.map { run in
            SourceEditorTextAttributeOverride(range: run.columns, attr: [.foregroundColor: tagAppearance.textColor(for: run)])
        }
    }
}

// MARK: - Layout Visualization

extension CommentDecorationController: LayoutVisualization {
    func didLayoutInContentView(_ contentView: SourceEditorContentView) {
        drawDecorations(in: contentView)
    }

    func layoutManagerDidInvalidateAllLayout(_ layoutManager: SourceEditorLayoutManager) {
        disclosureTargets = []
    }
}

// MARK: - Clicks

extension CommentDecorationController: SourceEditorViewEventConsumer {
    var consumerPriority: SourceEditorEventConsumerPriority { .high }

    func handleMouseEvent(_ event: NSEvent, in sourceEditorView: SourceEditorView) -> Bool {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.command), !disclosureTargets.isEmpty else { return false }
        let point = sourceEditorView.contentView.convert(event.locationInWindow, from: nil)
        guard let target = disclosureTargets.first(where: { $0.frame.contains(point) }) else { return false }
        let rows = tables.rows
        let wasCollapsed = rows.indices.contains(target.rowIndex) && isCollapsed(rows[target.rowIndex])
        showClick(on: target, turningFromCollapsed: wasCollapsed)
        toggle(rowAt: target.rowIndex, includingDescendants: event.modifierFlags.contains(.option))
        return true
    }
}

// MARK: - Cursor

extension CommentDecorationController: CursorRectOverrideProvider {
    /// The arrow over every triangle on screen: a click there toggles a row, so the pointer should
    /// not look as if it would place the insertion point. The editor adds these after its I-beam,
    /// in its own coordinates.
    func cursorRectsForContentRect(_ contentRect: CGRect, in sourceEditorView: SourceEditorView) -> [CursorRectOverride] {
        let contentView = sourceEditorView.contentView
        return disclosureTargets.compactMap { target in
            let rect = sourceEditorView.convert(target.frame, from: contentView).intersection(contentRect)
            return rect.isNull || rect.isEmpty ? nil : CursorRectOverride(cursor: .arrow, rect: rect)
        }
    }
}

// MARK: - Tables

extension CommentDecorationController {
    /// What the app's ``SourceEditorBridgingCommentTagAppearance`` said, read once: the layout
    /// hooks run while lines are built and must not call back into the app.
    struct TagAppearance {
        var fills: [SourceEditorBridgingCommentTagStyle: NSColor]
        var strokes: [SourceEditorBridgingCommentTagStyle: NSColor]
        var labels: [SourceEditorBridgingCommentTagStyle: NSColor]
        var value: NSColor
        var type: NSColor
        var name: NSColor
        var disclosure: NSColor
        var cornerRadius: CGFloat
        var strokeWidth: CGFloat
        var horizontalPadding: CGFloat

        static let fallback = TagAppearance(
            fills: Dictionary(uniqueKeysWithValues: SourceEditorBridgingCommentTagStyle.allCases.map { style in
                (style, style == .warning ? NSColor.systemOrange.withAlphaComponent(0.2) : NSColor.quaternaryLabelColor)
            }),
            strokes: [:],
            labels: [:],
            value: .labelColor,
            type: .labelColor,
            name: .labelColor,
            disclosure: .secondaryLabelColor,
            cornerRadius: 4,
            strokeWidth: 0,
            horizontalPadding: 4
        )

        func fill(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
            fills[style] ?? .quaternaryLabelColor
        }

        func stroke(for style: SourceEditorBridgingCommentTagStyle) -> NSColor? {
            strokeWidth > 0 ? strokes[style] : nil
        }

        /// A label takes the colour of the tag it lies in; one outside every tag, the note's.
        func textColor(for run: Run) -> NSColor {
            switch run.style {
            case .label: labels[run.tagStyle ?? .note] ?? labels[.note] ?? .secondaryLabelColor
            case .value: value
            case .type: type
            case .name: name
            case .concealed: .clear
            }
        }
    }

    struct Tag {
        let columns: Range<Int>
        let style: SourceEditorBridgingCommentTagStyle
        /// The columns that hold a space or a tab, for measuring a tag the editor wraps.
        let spaceColumns: [Int]
    }

    struct Run {
        let columns: Range<Int>
        let style: SourceEditorBridgingCommentRunStyle
        /// The style of the tag the run lies in, if any.
        let tagStyle: SourceEditorBridgingCommentTagStyle?
    }

    /// A triangle as drawn in a layout pass.
    struct DisclosureTarget {
        /// The cell the triangle sits in, which takes the click, in the content view's
        /// coordinates.
        let frame: CGRect
        let rowIndex: Int
        let layerIndex: Int
    }

    struct Row {
        /// The row's own line, which stays on screen when it is collapsed.
        let line: Int
        let disclosureColumns: Range<Int>
        let foldRange: Range<SourceEditorPosition>
        let startsCollapsed: Bool
        /// The rows whose fold range lies inside this one's, innermost or not.
        var descendantRowIndices: [Int]
    }

    /// The decorations of one text, filed by line the way the editor asks for them.
    struct Tables {
        let lineCount: Int
        let visibleColumnsByLine: [Int: [Range<Int>]]
        let shiftsByLine: [Int: [Int: CGFloat]]
        let runsByLine: [Int: [Run]]
        let tagsByLine: [Int: [Tag]]
        let rows: [Row]
        let rowIndicesByLine: [Int: [Int]]

        var isEmpty: Bool { lineCount == 0 }

        static let empty = Tables(
            lineCount: 0,
            visibleColumnsByLine: [:],
            shiftsByLine: [:],
            runsByLine: [:],
            tagsByLine: [:],
            rows: [],
            rowIndicesByLine: [:]
        )

        private init(
            lineCount: Int,
            visibleColumnsByLine: [Int: [Range<Int>]],
            shiftsByLine: [Int: [Int: CGFloat]],
            runsByLine: [Int: [Run]],
            tagsByLine: [Int: [Tag]],
            rows: [Row],
            rowIndicesByLine: [Int: [Int]]
        ) {
            self.lineCount = lineCount
            self.visibleColumnsByLine = visibleColumnsByLine
            self.shiftsByLine = shiftsByLine
            self.runsByLine = runsByLine
            self.tagsByLine = tagsByLine
            self.rows = rows
            self.rowIndicesByLine = rowIndicesByLine
        }

        init(decorations: SourceEditorBridgingCommentDecorations, source: String, tagPadding: CGFloat) {
            let lines = LineTable(source: source)

            // Hidden columns, per line, merged and sorted; the answer to the editor is what is
            // left of the line around them.
            var hiddenColumnsByLine: [Int: [Range<Int>]] = [:]
            for range in decorations.hiddenRanges.map(\.rangeValue) {
                guard let (line, columns) = lines.lineAndColumns(of: range) else { continue }
                hiddenColumnsByLine[line, default: []].append(columns)
            }
            var visibleColumnsByLine: [Int: [Range<Int>]] = [:]
            for (line, hiddenColumns) in hiddenColumnsByLine {
                visibleColumnsByLine[line] = Self.complement(of: hiddenColumns, withinLineOfLength: lines.length(ofLine: line))
            }

            var tagsByLine: [Int: [Tag]] = [:]
            var shiftsByLine: [Int: [Int: CGFloat]] = [:]
            let tagStyles = decorations.tagStyles
            if tagStyles.count == decorations.tagRanges.count {
                let textUnits = Array(source.utf16)
                for (range, styleValue) in zip(decorations.tagRanges.map(\.rangeValue), tagStyles) {
                    guard let style = SourceEditorBridgingCommentTagStyle(rawValue: styleValue.intValue),
                          let (line, columns) = lines.lineAndColumns(of: range),
                          !columns.isEmpty
                    else { continue }
                    let spaceColumns = (0 ..< range.length).compactMap { index -> Int? in
                        let unit = textUnits[range.location + index]
                        return unit == 0x20 || unit == 0x09 ? columns.lowerBound + index : nil
                    }
                    tagsByLine[line, default: []].append(Tag(columns: columns, style: style, spaceColumns: spaceColumns))

                    // Room for the padding on both sides. A shift on a hidden column might never be
                    // applied, so each goes on the first column at or after it that is drawn.
                    let visibleColumns = visibleColumnsByLine[line]
                    let lineLength = lines.length(ofLine: line)
                    if let start = Self.firstDrawnColumn(atOrAfter: columns.lowerBound, visibleColumns: visibleColumns, lineLength: lineLength) {
                        shiftsByLine[line, default: [:]][start, default: 0] += tagPadding
                    }
                    if let end = Self.firstDrawnColumn(atOrAfter: columns.upperBound, visibleColumns: visibleColumns, lineLength: lineLength) {
                        shiftsByLine[line, default: [:]][end, default: 0] += tagPadding
                    }
                }
            }

            var runsByLine: [Int: [Run]] = [:]
            let runStyles = decorations.runStyles
            if runStyles.count == decorations.runRanges.count {
                for (range, styleValue) in zip(decorations.runRanges.map(\.rangeValue), runStyles) {
                    guard let style = SourceEditorBridgingCommentRunStyle(rawValue: styleValue.intValue),
                          let (line, columns) = lines.lineAndColumns(of: range)
                    else { continue }
                    let enclosingTag = tagsByLine[line]?.first { $0.columns.lowerBound <= columns.lowerBound && columns.upperBound <= $0.columns.upperBound }
                    runsByLine[line, default: []].append(Run(columns: columns, style: style, tagStyle: enclosingTag?.style))
                }
            }

            var rows: [Row] = []
            let disclosureRanges = decorations.collapsibleDisclosureRanges.map(\.rangeValue)
            let foldRanges = decorations.collapsibleFoldRanges.map(\.rangeValue)
            let startsCollapsed = decorations.collapsibleStartsCollapsed
            if disclosureRanges.count == foldRanges.count, startsCollapsed.count == foldRanges.count {
                for index in foldRanges.indices {
                    guard let (line, disclosureColumns) = lines.lineAndColumns(of: disclosureRanges[index]),
                          let foldRange = lines.positionRange(of: foldRanges[index]),
                          foldRange.lowerBound.line == line,
                          foldRange.upperBound.line > line
                    else { continue }
                    rows.append(Row(
                        line: line,
                        disclosureColumns: disclosureColumns,
                        foldRange: foldRange,
                        startsCollapsed: startsCollapsed[index].boolValue,
                        descendantRowIndices: []
                    ))
                }
            }
            rows.sort { $0.foldRange.lowerBound < $1.foldRange.lowerBound }
            for index in rows.indices {
                let outer = rows[index].foldRange
                rows[index].descendantRowIndices = rows.indices.dropFirst(index + 1)
                    .prefix { rows[$0].foldRange.lowerBound < outer.upperBound }
                    .filter { rows[$0].foldRange.upperBound <= outer.upperBound }
            }
            var rowIndicesByLine: [Int: [Int]] = [:]
            for (index, row) in rows.enumerated() {
                rowIndicesByLine[row.line, default: []].append(index)
            }

            self.init(
                lineCount: lines.lineCount,
                visibleColumnsByLine: visibleColumnsByLine,
                shiftsByLine: shiftsByLine,
                runsByLine: runsByLine,
                tagsByLine: tagsByLine,
                rows: rows,
                rowIndicesByLine: rowIndicesByLine
            )
        }

        /// What is left of a line of `length` columns once `hiddenColumns` are taken out. Never
        /// an empty array: the editor reads `[]` as "hide nothing", so a line hidden whole is
        /// answered with an empty range.
        static func complement(of hiddenColumns: [Range<Int>], withinLineOfLength length: Int) -> [Range<Int>] {
            var visibleColumns: [Range<Int>] = []
            var nextVisibleColumn = 0
            for hidden in hiddenColumns.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let lower = min(max(hidden.lowerBound, 0), length)
                let upper = min(max(hidden.upperBound, lower), length)
                if lower > nextVisibleColumn {
                    visibleColumns.append(nextVisibleColumn ..< lower)
                }
                nextVisibleColumn = max(nextVisibleColumn, upper)
            }
            if nextVisibleColumn < length {
                visibleColumns.append(nextVisibleColumn ..< length)
            }
            return visibleColumns.isEmpty ? [0 ..< 0] : visibleColumns
        }

        /// The first column at or after `column` that is drawn, or nil when nothing after it is.
        static func firstDrawnColumn(atOrAfter column: Int, visibleColumns: [Range<Int>]?, lineLength: Int) -> Int? {
            guard column < lineLength else { return nil }
            guard let visibleColumns else { return column }
            for visible in visibleColumns where visible.upperBound > column {
                return max(visible.lowerBound, column)
            }
            return nil
        }
    }

    /// Where each line of a text starts, in UTF-16 offsets — the units the app's ranges are in
    /// and, for the column of a `SourceEditorPosition`, the editor's too.
    struct LineTable {
        private let lineStarts: [Int]
        private let textLength: Int

        init(source: String) {
            var lineStarts = [0]
            var offset = 0
            for unit in source.utf16 {
                offset += 1
                if unit == 0x0A {
                    lineStarts.append(offset)
                }
            }
            self.lineStarts = lineStarts
            self.textLength = offset
        }

        var lineCount: Int { lineStarts.count }

        /// The line's length without its line break.
        func length(ofLine line: Int) -> Int {
            guard lineStarts.indices.contains(line) else { return 0 }
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : textLength
            return max(end - lineStarts[line], 0)
        }

        func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return low
        }

        /// The line a range lies on and its columns there; nil for a range that crosses a line
        /// break or runs past the line's end.
        func lineAndColumns(of range: NSRange) -> (line: Int, columns: Range<Int>)? {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= textLength else { return nil }
            let line = line(containing: range.location)
            let lowerColumn = range.location - lineStarts[line]
            let upperColumn = lowerColumn + range.length
            guard upperColumn <= length(ofLine: line) else { return nil }
            return (line, lowerColumn ..< upperColumn)
        }

        /// The range as editor positions; nil when it runs past the end of the text.
        func positionRange(of range: NSRange) -> Range<SourceEditorPosition>? {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= textLength else { return nil }
            let lowerLine = line(containing: range.location)
            let upperLine = line(containing: NSMaxRange(range))
            let lower = SourceEditorPosition(line: lowerLine, col: range.location - lineStarts[lowerLine])
            let upper = SourceEditorPosition(line: upperLine, col: NSMaxRange(range) - lineStarts[upperLine])
            return lower ..< upper
        }
    }
}

extension CommentDecorationController.TagAppearance {
    init(_ appearance: SourceEditorBridgingCommentTagAppearance) {
        var fills: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var strokes: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var labels: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        for style in SourceEditorBridgingCommentTagStyle.allCases {
            fills[style] = appearance.fillColor(for: style)
            strokes[style] = appearance.strokeColor(for: style)
            labels[style] = appearance.labelColor(for: style)
        }
        self.init(
            fills: fills,
            strokes: strokes,
            labels: labels,
            value: appearance.valueColor,
            type: appearance.typeColor,
            name: appearance.nameColor,
            disclosure: appearance.disclosureColor,
            cornerRadius: appearance.cornerRadius,
            strokeWidth: appearance.strokeWidth,
            horizontalPadding: appearance.horizontalPadding
        )
    }
}

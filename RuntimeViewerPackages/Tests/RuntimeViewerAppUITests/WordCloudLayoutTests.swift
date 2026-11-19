#if os(macOS)

import AppKit
import Testing
@testable import RuntimeViewerUI

/// The naming word cloud's geometry and canvas: words placed without
/// overlapping, inside a canvas sized from them, the same way every time;
/// sizes by count; a click finds the word under it.
@Suite("Word cloud layout and view")
struct WordCloudLayoutTests {
    /// Word sizes as a cloud has them: a few large, many small, the largest
    /// first. Made by a fixed linear congruential sequence, so every run
    /// lays out the same words.
    private static func wordSizes(count: Int) -> [CGSize] {
        var state: UInt64 = 0x5EED
        func nextFraction() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
        return (0 ..< count).map { index in
            let fontSize = max(12, 120 * (1 / CGFloat(index + 1)).squareRoot())
            let characterCount = 3 + Int(nextFraction() * 9)
            return CGSize(width: (fontSize * 0.6 * CGFloat(characterCount)).rounded(.up), height: (fontSize * 1.2).rounded(.up))
        }
    }

    @Test("no two words overlap, and every word lies inside the canvas")
    func noOverlapInsideCanvas() {
        let layout = WordCloudLayout(wordSizes: Self.wordSizes(count: 300))
        let frames = layout.frames.compactMap(\.self)
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        #expect(layout.unplacedCount == 0)
        #expect(frames.allSatisfy { canvas.contains($0) })
        var overlaps = 0
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] where frame.intersects(other) {
                overlaps += 1
            }
        }
        #expect(overlaps == 0)
    }

    @Test("each word keeps its measured size")
    func sizesKept() {
        let sizes = Self.wordSizes(count: 50)
        let layout = WordCloudLayout(wordSizes: sizes)

        #expect(zip(sizes, layout.frames).allSatisfy { size, frame in frame?.size == size })
    }

    @Test("the same words are laid out the same way every time")
    func deterministic() {
        let sizes = Self.wordSizes(count: 200)
        #expect(WordCloudLayout(wordSizes: sizes) == WordCloudLayout(wordSizes: sizes))
    }

    @Test("the canvas is sized from the words, not from a window, in the proportions asked for")
    func canvasFromWords() {
        let small = WordCloudLayout(wordSizes: Self.wordSizes(count: 50))
        let large = WordCloudLayout(wordSizes: Self.wordSizes(count: 500))

        #expect(large.canvasSize.width * large.canvasSize.height > small.canvasSize.width * small.canvasSize.height * 2)
        let aspectRatio = large.canvasSize.width / large.canvasSize.height
        #expect(abs(aspectRatio - 1.6) < 0.05)
    }

    @Test("a word wider than the area alone would give still fits")
    func wideWordFits() {
        let layout = WordCloudLayout(wordSizes: [CGSize(width: 2000, height: 20), CGSize(width: 30, height: 14)])

        #expect(layout.canvasSize.width >= 2000)
        #expect(layout.unplacedCount == 0)
    }

    @Test("font sizes follow the square root of the count, between 12 and 120 points, heavier as they grow")
    func typography() {
        #expect(WordCloudTypography.fontSize(count: 400, maximumCount: 400) == 120)
        #expect(WordCloudTypography.fontSize(count: 100, maximumCount: 400) == 60)
        #expect(WordCloudTypography.fontSize(count: 1, maximumCount: 400) == 12)
        #expect(WordCloudTypography.fontWeight(forSize: 120) == .bold)
        #expect(WordCloudTypography.fontWeight(forSize: 30) == .semibold)
        #expect(WordCloudTypography.fontWeight(forSize: 20) == .medium)
        #expect(WordCloudTypography.fontWeight(forSize: 12) == .regular)
    }

    @MainActor
    @Test("a click finds the word under it, and the canvas exports whole")
    func viewHitTestingAndExport() async throws {
        let view = WordCloudView(frame: .zero)
        let words = (0 ..< 40).map { index in
            WordCloudView.Word(identifier: "word\(index)", text: "Word\(index)", count: 100 - index, color: .systemBlue)
        }

        await view.setWords(words)

        #expect(view.wordCount == 40)
        #expect(view.placedWordCount == 40)
        #expect(view.frame.size.width > 0)
        let frame = try #require(view.frameOfWord(withIdentifier: "word0"))
        #expect(view.wordIdentifier(at: CGPoint(x: frame.midX, y: frame.midY)) == "word0")
        #expect(view.wordIdentifier(at: CGPoint(x: 1, y: 1)) == nil)

        let png = try #require(view.pngDataOfWholeCanvas())
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == Int(view.bounds.width * 2))

        let cappedPNG = try #require(view.pngDataOfWholeCanvas(maximumScale: 2, maximumPixelCount: 10_000))
        let cappedImage = try #require(NSBitmapImageRep(data: cappedPNG))
        #expect(CGFloat(cappedImage.pixelsWide * cappedImage.pixelsHigh) <= 10_000)
    }

    @Test("words below 18 points are drawn at 60% opacity, larger ones in full colour")
    func wordsBelowEighteenPointsAreTranslucent() {
        #expect(WordCloudTypography.opacity(forSize: 12) == 0.6)
        #expect(WordCloudTypography.opacity(forSize: 17.5) == 0.6)
        #expect(WordCloudTypography.opacity(forSize: 18) == 1)
        #expect(WordCloudTypography.opacity(forSize: 120) == 1)
    }

    @MainActor
    @Test("the words' bounding rectangle holds every word drawn and nothing more")
    func boundingRectCoversEveryPlacedWord() async throws {
        let view = WordCloudView(frame: .zero)
        #expect(view.wordsBoundingRect == nil)
        let words = Self.viewWords(count: 60)

        await view.setWords(words)

        let boundingRect = try #require(view.wordsBoundingRect)
        let frames = words.compactMap { view.frameOfWord(withIdentifier: $0.identifier) }
        #expect(frames.count == view.placedWordCount)
        #expect(frames.allSatisfy { boundingRect.contains($0) })
        #expect(frames.reduce(frames[0]) { $0.union($1) } == boundingRect)
        #expect(CGRect(origin: .zero, size: view.bounds.size).contains(boundingRect))
    }

    @MainActor
    @Test("with the hand tool on, a click on a word selects nothing; with it off, the click reports the word")
    func handToolClickOnAWordSelectsNothing() async throws {
        let view = WordCloudView(frame: .zero)
        await view.setWords(Self.viewWords(count: 20))
        var clickedIdentifiers: [String] = []
        view.wordClickHandler = { clickedIdentifiers.append($0) }
        let frame = try #require(view.frameOfWord(withIdentifier: "word0"))
        let locationInWindow = view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)

        try Self.click(view, at: locationInWindow)
        #expect(clickedIdentifiers == ["word0"])

        view.isHandToolActive = true
        try Self.click(view, at: locationInWindow)
        #expect(clickedIdentifiers == ["word0"])

        view.isHandToolActive = false
        try Self.click(view, at: locationInWindow)
        #expect(clickedIdentifiers == ["word0", "word0"])
    }

    private static func viewWords(count: Int) -> [WordCloudView.Word] {
        (0 ..< count).map { index in
            WordCloudView.Word(identifier: "word\(index)", text: "Word\(index)", count: 100 - index, color: .systemBlue)
        }
    }

    /// A press and a release at the same point: a click, not a drag.
    @MainActor
    private static func click(_ view: NSView, at locationInWindow: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type,
                location: locationInWindow,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }
}

#endif

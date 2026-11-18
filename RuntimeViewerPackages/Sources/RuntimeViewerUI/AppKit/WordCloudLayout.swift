#if os(macOS)

import CoreGraphics
import Foundation

/// Where each word of a word cloud goes: pure geometry over sizes measured
/// beforehand, so it runs off the main thread and gives the same picture for
/// the same words every time.
///
/// The canvas is sized from the words, not from a window: the words take
/// about `fillRatio` of its area, in the proportions of `aspectRatio`. Words
/// are placed in the order given — the caller puts the largest first — each
/// at the first point of a spiral out of the canvas's centre where it
/// overlaps nothing and stays inside the canvas, all of them horizontal. A
/// word that finds no such point is left out and counted in
/// `unplacedCount`; with the area the canvas is given that rarely happens.
public struct WordCloudLayout: Sendable, Equatable {
    /// The canvas, in points; its origin is the top-left corner.
    public let canvasSize: CGSize

    /// The frame of each word placed, by its index in the sizes given; `nil`
    /// for a word left out.
    public let frames: [CGRect?]

    public var unplacedCount: Int {
        frames.count { $0 == nil }
    }

    /// - Parameters:
    ///   - wordSizes: Each word's text size, in the order to place them.
    ///   - spacing: The gap kept around every word.
    ///   - fillRatio: The share of the canvas the words take.
    ///   - aspectRatio: The canvas's width over its height.
    public init(wordSizes: [CGSize], spacing: CGFloat = 4, fillRatio: CGFloat = 0.4, aspectRatio: CGFloat = 1.6) {
        let paddedArea = wordSizes.reduce(CGFloat(0)) { total, size in
            total + (size.width + spacing * 2) * (size.height + spacing * 2)
        }
        let widestWord = wordSizes.map { $0.width + spacing * 2 }.max() ?? 0
        let tallestWord = wordSizes.map { $0.height + spacing * 2 }.max() ?? 0
        let canvasArea = paddedArea / max(fillRatio, 0.05)
        let width = max((canvasArea * aspectRatio).squareRoot(), widestWord).rounded(.up)
        let height = max(canvasArea / max(width, 1), tallestWord).rounded(.up)
        canvasSize = CGSize(width: width, height: height)

        var grid = OccupancyGrid(canvasSize: canvasSize)
        let center = CGPoint(x: width / 2, y: height / 2)
        // An elliptical Archimedean spiral, stretched to the canvas's proportions.
        // Its turns lie about 19 points apart, less than the smallest word is
        // tall with its spacing, so no gap a word fits in is stepped over.
        let radiusGrowthPerRadian: CGFloat = 3
        let angleStep: CGFloat = 0.2
        let arcStep: CGFloat = 8
        let maximumRadius = (width * width + height * height).squareRoot() / 2
        let horizontalStretch = aspectRatio.squareRoot()
        let verticalStretch = 1 / horizontalStretch

        var frames: [CGRect?] = []
        frames.reserveCapacity(wordSizes.count)
        for size in wordSizes {
            let paddedSize = CGSize(width: size.width + spacing * 2, height: size.height + spacing * 2)
            var placedFrame: CGRect?
            var angle: CGFloat = 0
            while true {
                let radius = radiusGrowthPerRadian * angle
                if radius > maximumRadius * max(horizontalStretch, 1) { break }
                let candidateCenter = CGPoint(
                    x: center.x + radius * cos(angle) * horizontalStretch,
                    y: center.y + radius * sin(angle) * verticalStretch
                )
                let candidate = CGRect(
                    x: (candidateCenter.x - paddedSize.width / 2).rounded(),
                    y: (candidateCenter.y - paddedSize.height / 2).rounded(),
                    width: paddedSize.width,
                    height: paddedSize.height
                )
                if candidate.minX >= 0, candidate.minY >= 0, candidate.maxX <= width, candidate.maxY <= height,
                   !grid.intersects(candidate) {
                    grid.insert(candidate)
                    placedFrame = candidate.insetBy(dx: spacing, dy: spacing)
                    break
                }
                // Steps of about the same arc length: smaller angles further out.
                angle += radius < 1 ? angleStep : min(angleStep, arcStep / radius)
            }
            frames.append(placedFrame)
        }
        self.frames = frames
    }
}

/// The frames placed so far, filed in square cells so that a candidate is
/// checked only against the frames near it.
private struct OccupancyGrid {
    private let cellSide: CGFloat = 48
    private let columnCount: Int
    private let rowCount: Int
    private var framesByCell: [[CGRect]]

    init(canvasSize: CGSize) {
        columnCount = max(1, Int((canvasSize.width / cellSide).rounded(.up)))
        rowCount = max(1, Int((canvasSize.height / cellSide).rounded(.up)))
        framesByCell = Array(repeating: [], count: columnCount * rowCount)
    }

    func intersects(_ frame: CGRect) -> Bool {
        guard let (columns, rows) = cellRanges(covering: frame) else { return false }
        for row in rows {
            for column in columns {
                for placedFrame in framesByCell[row * columnCount + column] where placedFrame.intersects(frame) {
                    return true
                }
            }
        }
        return false
    }

    mutating func insert(_ frame: CGRect) {
        guard let (columns, rows) = cellRanges(covering: frame) else { return }
        for row in rows {
            for column in columns {
                framesByCell[row * columnCount + column].append(frame)
            }
        }
    }

    private func cellRanges(covering frame: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let firstColumn = max(0, Int(frame.minX / cellSide))
        let lastColumn = min(columnCount - 1, Int(frame.maxX / cellSide))
        let firstRow = max(0, Int(frame.minY / cellSide))
        let lastRow = min(rowCount - 1, Int(frame.maxY / cellSide))
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return nil }
        return (firstColumn ... lastColumn, firstRow ... lastRow)
    }
}

#endif

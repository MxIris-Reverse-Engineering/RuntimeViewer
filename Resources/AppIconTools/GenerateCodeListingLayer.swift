#!/usr/bin/env swift

// Regenerates the app icon's code-listing layer as SVG outlines.
//
//     swift Resources/AppIconTools/GenerateCodeListingLayer.swift \
//         "Resources/AppIcon.icon/Assets/CodeListing.svg"
//
// The layer cannot be edited by hand — it is a few hundred glyph outlines — so every change to
// the snippet, the font or the type size goes through this file.
//
// Why outlines rather than a bitmap or an SVG <text> element:
//
//   * Icon Composer's `fill-specializations` only apply to vector layers. A bitmap cannot be
//     recoloured for the dark or tinted appearance, which is the whole reason this layer was
//     split out of the original single-bitmap foreground.
//   * An SVG <text> element would depend on the font being installed wherever the icon is
//     compiled. Outlines do not.
//
// The metrics below were measured off the original `Background 2.png` foreground (824×824),
// by connected-component analysis of its white pixels, so that the rebuilt layer lands exactly
// where the baked-in one did:
//
//   * left edge of the first line's ink: x = 128
//   * top of the first line's ink:       y = 112
//   * baseline-to-baseline advance:      38
//   * first line's ink width:            568
//
// SF Mono Regular at 29 pt reproduces that ink width to within a pixel (568.6); Menlo cannot
// match the width and height simultaneously at any size.
//
// The 824 coordinate space is deliberate: Icon Composer treats an SVG's viewBox units and a
// bitmap's pixels alike, so a 824-unit viewBox at the layer's existing `scale` of 1.3 covers
// exactly the region the 824-pixel bitmap used to.

import AppKit
import CoreText

let interfaceListing = [
    "@interface NSObject <NSObject> {",
    "    Class isa;",
    "}",
    "",
    "+ (void)load;",
    "+ (void)initialize;",
    "- (instancetype)init;",
    "+ (instancetype)new;",
    "+ (instancetype)allocWithZone:",
    "(struct _NSZone *)zone;",
    "+ (instancetype)alloc;",
    "- (void)dealloc;",
    "- (id)copy;",
    "- (id)mutableCopy;",
    "",
    "@end",
]

let fontName = "SFMono-Regular"
let pointSize: CGFloat = 29
let baselineAdvance: CGFloat = 38
let canvasSize = 824
let firstLineInkOrigin = CGPoint(x: 128, y: 112)

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: GenerateCodeListingLayer.swift <output.svg>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

guard let font = NSFont(name: fontName, size: pointSize) else {
    FileHandle.standardError.write(Data("font not available: \(fontName)\n".utf8))
    exit(1)
}

struct InkBounds {
    var minimumX = CGFloat.infinity, minimumY = CGFloat.infinity
    var maximumX = -CGFloat.infinity, maximumY = -CGFloat.infinity

    mutating func insert(_ point: CGPoint) {
        minimumX = min(minimumX, point.x); maximumX = max(maximumX, point.x)
        minimumY = min(minimumY, point.y); maximumY = max(maximumY, point.y)
    }
}

var glyphPathData: [String] = []
var firstLineInk = InkBounds()

func format(_ value: CGFloat) -> String { String(format: "%.2f", value) }

for (lineIndex, line) in interfaceListing.enumerated() where !line.isEmpty {
    let baselineY = CGFloat(lineIndex) * baselineAdvance
    let typesetLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))

    for run in CTLineGetGlyphRuns(typesetLine) as! [CTRun] {
        let glyphCount = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
        var glyphPositions = [CGPoint](repeating: .zero, count: glyphCount)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &glyphPositions)

        let runFont = unsafeBitCast(
            CFDictionaryGetValue(CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()),
            to: CTFont.self
        )

        for glyphIndex in 0..<glyphCount {
            guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[glyphIndex], nil) else { continue }
            // Glyph space is y-up; SVG is y-down. Flip, then drop the glyph onto its line's baseline.
            var transform = CGAffineTransform(translationX: glyphPositions[glyphIndex].x, y: baselineY)
                .scaledBy(x: 1, y: -1)
            guard let placedOutline = outline.copy(using: &transform) else { continue }

            var commands: [String] = []
            placedOutline.applyWithBlock { elementPointer in
                let element = elementPointer.pointee
                func record(_ point: CGPoint) {
                    if lineIndex == 0 { firstLineInk.insert(point) }
                }
                switch element.type {
                case .moveToPoint:
                    record(element.points[0])
                    commands.append("M\(format(element.points[0].x)) \(format(element.points[0].y))")
                case .addLineToPoint:
                    record(element.points[0])
                    commands.append("L\(format(element.points[0].x)) \(format(element.points[0].y))")
                case .addQuadCurveToPoint:
                    record(element.points[0]); record(element.points[1])
                    commands.append("Q\(format(element.points[0].x)) \(format(element.points[0].y))"
                                    + " \(format(element.points[1].x)) \(format(element.points[1].y))")
                case .addCurveToPoint:
                    record(element.points[0]); record(element.points[1]); record(element.points[2])
                    commands.append("C\(format(element.points[0].x)) \(format(element.points[0].y))"
                                    + " \(format(element.points[1].x)) \(format(element.points[1].y))"
                                    + " \(format(element.points[2].x)) \(format(element.points[2].y))")
                case .closeSubpath:
                    commands.append("Z")
                @unknown default:
                    break
                }
            }
            if !commands.isEmpty { glyphPathData.append(commands.joined(separator: " ")) }
        }
    }
}

let measuredInkWidth = firstLineInk.maximumX - firstLineInk.minimumX
print(String(format: "%@ @ %.0fpt — first line ink width %.1f (bitmap measured 568)", fontName, pointSize, measuredInkWidth))

// Shift the whole block so the first line's ink starts exactly where the bitmap's did.
let offsetX = firstLineInkOrigin.x - firstLineInk.minimumX
let offsetY = firstLineInkOrigin.y - firstLineInk.minimumY

let paths = glyphPathData.map { "  <path d=\"\($0)\"/>" }.joined(separator: "\n")
let document = """
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by Resources/AppIconTools/GenerateCodeListingLayer.swift. Do not edit by hand. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(canvasSize) \(canvasSize)">
 <g fill="#FFFFFF" fill-rule="nonzero" transform="translate(\(format(offsetX)), \(format(offsetY)))">
\(paths)
 </g>
</svg>

"""

try! document.write(toFile: outputPath, atomically: true, encoding: .utf8)
print("wrote \(outputPath) — \(glyphPathData.count) glyph outlines, \(document.count) bytes")

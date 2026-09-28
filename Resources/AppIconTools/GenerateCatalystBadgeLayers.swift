#!/usr/bin/env swift

// Regenerates the CATALYST badge on the Catalyst helper's icon as two SVG layers.
//
//     swift Resources/AppIconTools/GenerateCatalystBadgeLayers.swift \
//         "RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/CatalystHelperIcon.icon/Assets"
//
// writes CatalystLozenge.svg and CatalystWordmark.svg into that directory.
//
// The badge is AppIconBeta.icon's BETA badge with a different word: the same lozenge outline,
// the same colours and the same group settings in icon.json, so the helper's icon reads as the
// app's icon plus a label, the way the beta build's does. CATALYST has twice as many letters as
// BETA, which forces two departures:
//
//   * The wordmark is set smaller. At BETA's cap height of 136 units the word would run about
//     840 units wide and cover the whole lower half of the icon; at 104 the lozenge still reached
//     within 135 units of either edge and looked crowded. 96 leaves the badge about 700 units wide.
//   * The lozenge is BETA's, scaled by the same ratio and then stretched horizontally: both end
//     caps keep Xcode's exact curves, and only the straight top and bottom edges grow.
//
// Xcode's BETA wordmark arrived as outlines rather than as a font this script could name, so the
// typeface is the nearest system match — SF Pro at semi-condensed width and black weight. The script
// prints the width that face gives "BETA" at BETA's cap height next to the 426 units Xcode's
// wordmark measures, so a change of weight or width can be judged against the original.
//
// Outlines rather than an SVG <text> element, for the reason GenerateCodeListingLayer.swift
// gives. Filled paths only: Icon Composer through 1.6 renders `stroke` as a fill (see
// Documentations/ResolvedIssues/2026-09-21-icon-strokes-rendered-as-fills.md).
//
// Coordinates are in the 1024-unit viewBox BETA's layers use, at a layer scale of 1. The badge's
// right and bottom edges sit where BETA's do, so it hugs the same corner and grows leftwards;
// icon.json then applies BETA's translation of (-33, 40) points to both layers.

import AppKit
import CoreText

let badgeWord = "CATALYST"
let badgeCapHeight: CGFloat = 96
// Halfway between .condensed (-0.2) and .standard (0), which the system face resolves to its
// SemiCondensed instance, at black weight: that sets "BETA" 424 units wide at BETA's cap height,
// against Xcode's 426. The neighbours miss by far more — semi-condensed heavy gives 412, and heavy
// at .condensed and .standard gives 357 and 466.
let badgeFontWeight = NSFont.Weight.black
let badgeFontWidth = NSFont.Width(rawValue: -0.1)

// BETA's badge, measured off Resources/AppIconBeta.icon/Assets/BetaLozenge.svg and BetaWordmark.svg.
let betaCapHeight: CGFloat = 136
let betaWordmarkWidth: CGFloat = 426
let betaLozengeRight: CGFloat = 929
let betaLozengeBottom: CGFloat = 898
let betaLozengeHalfHeight: CGFloat = 130
// Gap between the wordmark's ink and the lozenge's outer edge, averaged over both sides: BETA's
// is 79 on the left and 64 on the right, an optical offset for the B's flat stem that a word
// starting with a round C does not want.
let betaHorizontalPadding: CGFloat = 71.5
// Xcode's end caps, relative to where each meets the straight edge at the lozenge's vertical
// centre. The left one is a unit wider than the right one; both are kept as drawn.
let betaLeftCapWidth: CGFloat = 141
let betaLeftCapControlOffset: CGFloat = 80.862
let betaRightCapWidth: CGFloat = 140
let betaRightCapControlOffset: CGFloat = 80.8804
let betaCapCurveControlHeight: CGFloat = 82.066

let canvasSize: CGFloat = 1024

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: GenerateCatalystBadgeLayers.swift <icon Assets directory>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    FileHandle.standardError.write(Data("not a directory: \(outputDirectory.path)\n".utf8))
    exit(1)
}

func format(_ value: CGFloat) -> String { String(format: "%.2f", value) }

func badgeFont(capHeight: CGFloat) -> NSFont {
    let referencePointSize: CGFloat = 100
    let referenceFont = NSFont.systemFont(ofSize: referencePointSize, weight: badgeFontWeight, width: badgeFontWidth)
    return NSFont.systemFont(
        ofSize: referencePointSize * capHeight / referenceFont.capHeight,
        weight: badgeFontWeight,
        width: badgeFontWidth
    )
}

/// The word's glyph outlines on a baseline at y = 0, already flipped into SVG's y-down space.
func glyphOutlines(of text: String, in font: NSFont) -> [CGPath] {
    let typesetLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    var outlines: [CGPath] = []

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
            var transform = CGAffineTransform(translationX: glyphPositions[glyphIndex].x, y: 0).scaledBy(x: 1, y: -1)
            guard let placedOutline = outline.copy(using: &transform) else { continue }
            outlines.append(placedOutline)
        }
    }
    return outlines
}

func inkBounds(of outlines: [CGPath]) -> CGRect {
    outlines.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
}

func svgPathData(for path: CGPath) -> String {
    var commands: [String] = []
    path.applyWithBlock { elementPointer in
        let element = elementPointer.pointee
        switch element.type {
        case .moveToPoint:
            commands.append("M\(format(element.points[0].x)) \(format(element.points[0].y))")
        case .addLineToPoint:
            commands.append("L\(format(element.points[0].x)) \(format(element.points[0].y))")
        case .addQuadCurveToPoint:
            commands.append("Q\(format(element.points[0].x)) \(format(element.points[0].y))"
                            + " \(format(element.points[1].x)) \(format(element.points[1].y))")
        case .addCurveToPoint:
            commands.append("C\(format(element.points[0].x)) \(format(element.points[0].y))"
                            + " \(format(element.points[1].x)) \(format(element.points[1].y))"
                            + " \(format(element.points[2].x)) \(format(element.points[2].y))")
        case .closeSubpath:
            commands.append("Z")
        @unknown default:
            break
        }
    }
    return commands.joined(separator: " ")
}

// The face checked against Xcode's own BETA.
let betaComparisonWidth = inkBounds(of: glyphOutlines(of: "BETA", in: badgeFont(capHeight: betaCapHeight))).width
print(String(format: "\"BETA\" at cap height %.0f: ink width %.1f (Xcode's wordmark measures %.0f)",
             betaCapHeight, betaComparisonWidth, betaWordmarkWidth))

// The wordmark.
let wordmarkOutlines = glyphOutlines(of: badgeWord, in: badgeFont(capHeight: badgeCapHeight))
let wordmarkInk = inkBounds(of: wordmarkOutlines)

// The lozenge, sized around the wordmark's ink.
let badgeScale = badgeCapHeight / betaCapHeight
let lozengeWidth = wordmarkInk.width + 2 * betaHorizontalPadding * badgeScale
let lozengeLeft = betaLozengeRight - lozengeWidth
let lozengeCenterY = betaLozengeBottom - betaLozengeHalfHeight * badgeScale
let halfHeight = betaLozengeHalfHeight * badgeScale
let curveControlHeight = betaCapCurveControlHeight * badgeScale
let straightLeft = lozengeLeft + betaLeftCapWidth * badgeScale
let straightRight = lozengeLeft + lozengeWidth - betaRightCapWidth * badgeScale
guard straightRight > straightLeft else {
    FileHandle.standardError.write(Data("the word is too short for the lozenge's end caps\n".utf8))
    exit(1)
}
let leftCapOuter = straightLeft - betaLeftCapWidth * badgeScale
let leftCapControl = straightLeft - betaLeftCapControlOffset * badgeScale
let rightCapOuter = straightRight + betaRightCapWidth * badgeScale
let rightCapControl = straightRight + betaRightCapControlOffset * badgeScale
let lozengeTop = lozengeCenterY - halfHeight
let lozengeBottom = lozengeCenterY + halfHeight

// Same drawing order as BetaLozenge.svg: along the bottom edge leftwards, round the left cap,
// along the top edge rightwards, round the right cap.
let lozengePathData = [
    "M\(format(straightRight)) \(format(lozengeBottom))",
    "L\(format(straightLeft)) \(format(lozengeBottom))",
    "C\(format(leftCapControl)) \(format(lozengeBottom)) \(format(leftCapOuter)) \(format(lozengeCenterY + curveControlHeight)) \(format(leftCapOuter)) \(format(lozengeCenterY))",
    "C\(format(leftCapOuter)) \(format(lozengeCenterY - curveControlHeight)) \(format(leftCapControl)) \(format(lozengeTop)) \(format(straightLeft)) \(format(lozengeTop))",
    "L\(format(straightRight)) \(format(lozengeTop))",
    "C\(format(rightCapControl)) \(format(lozengeTop)) \(format(rightCapOuter)) \(format(lozengeCenterY - curveControlHeight)) \(format(rightCapOuter)) \(format(lozengeCenterY))",
    "C\(format(rightCapOuter)) \(format(lozengeCenterY + curveControlHeight)) \(format(rightCapControl)) \(format(lozengeBottom)) \(format(straightRight)) \(format(lozengeBottom))",
    "Z",
].joined(separator: " ")

// Centre the wordmark's ink in the lozenge.
let wordmarkOffsetX = lozengeLeft + lozengeWidth / 2 - wordmarkInk.midX
let wordmarkOffsetY = lozengeCenterY - wordmarkInk.midY

print(String(format: "\"%@\" at cap height %.0f: ink %.1f × %.1f; lozenge %.1f × %.1f, x %.1f–%.1f, y %.1f–%.1f",
             badgeWord, badgeCapHeight, wordmarkInk.width, wordmarkInk.height,
             lozengeWidth, lozengeBottom - lozengeTop, lozengeLeft, lozengeLeft + lozengeWidth, lozengeTop, lozengeBottom))

let header = """
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by Resources/AppIconTools/GenerateCatalystBadgeLayers.swift. Do not edit by hand. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(canvasSize)) \(Int(canvasSize))">
"""

let lozengeDocument = """
\(header)
 <path fill="#0C0C0C" d="\(lozengePathData)"/>
</svg>

"""

let wordmarkPaths = wordmarkOutlines.map { "  <path d=\"\(svgPathData(for: $0))\"/>" }.joined(separator: "\n")
let wordmarkDocument = """
\(header)
 <g fill="#FFFFFF" fill-rule="nonzero" transform="translate(\(format(wordmarkOffsetX)), \(format(wordmarkOffsetY)))">
\(wordmarkPaths)
 </g>
</svg>

"""

let lozengeURL = outputDirectory.appendingPathComponent("CatalystLozenge.svg")
let wordmarkURL = outputDirectory.appendingPathComponent("CatalystWordmark.svg")
try! lozengeDocument.write(to: lozengeURL, atomically: true, encoding: .utf8)
try! wordmarkDocument.write(to: wordmarkURL, atomically: true, encoding: .utf8)
print("wrote \(lozengeURL.path) and \(wordmarkURL.path) — \(wordmarkOutlines.count) glyph outlines")

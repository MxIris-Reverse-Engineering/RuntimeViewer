#!/usr/bin/env swift

// Regenerates a word badge — the CATALYST badge on the Catalyst helper's icon, or the DEBUG badge
// on the Debug builds' icon — as two SVG layers.
//
//     swift Resources/AppIconTools/GenerateBadgeLayers.swift catalyst \
//         "RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/CatalystHelperIcon.icon/Assets"
//     swift Resources/AppIconTools/GenerateBadgeLayers.swift debug "Resources/AppIconDebug.icon/Assets"
//
// writes <Prefix>Lozenge.svg and <Prefix>Wordmark.svg into that directory (CatalystLozenge.svg and
// CatalystWordmark.svg, DebugLozenge.svg and DebugWordmark.svg). `--cap-height <units>` after the
// directory overrides the preset's cap height, for trying sizes before settling one in the preset.
//
// Every badge is AppIconBeta.icon's BETA badge with a different word: the same lozenge outline,
// the same colours and the same group settings in icon.json, so the icon reads as the app's icon
// plus a label, the way the beta build's does. A preset holds only what the word forces:
//
//   * The cap height. A longer word is set smaller, or the badge covers the icon's lower half.
//     CATALYST has twice BETA's letters: at BETA's cap height of 136 units it would run about 840
//     units wide; at 104 the lozenge still reached within 135 units of either edge and looked
//     crowded. 96 leaves the badge about 700 units wide. DEBUG's cap height was picked from
//     renders of three candidates; the preset's comment gives the measurements.
//   * The padding between the wordmark's ink and the lozenge's outer edge, in BETA's units.
//     BETA's is 79 on the left and 64 on the right, an optical offset for the B's flat stem. DEBUG
//     opens with a flat stem too and keeps it; CATALYST opens with a round C, which does not want
//     the offset, and takes the average on both sides.
//
// The lozenge is BETA's, scaled by the cap-height ratio and then stretched horizontally: both end
// caps keep Xcode's exact curves, and only the straight top and bottom edges grow.
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

struct BadgePreset {
    /// The word set on the badge.
    let word: String
    /// The wordmark's cap height, in the 1024-unit viewBox.
    let capHeight: CGFloat
    /// The gap between the wordmark's ink and the lozenge's outer edge on each side, in BETA's
    /// units: scaled by capHeight / 136 like every other BETA measurement.
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    /// The two files written are <fileNamePrefix>Lozenge.svg and <fileNamePrefix>Wordmark.svg.
    let fileNamePrefix: String
}

let badgePresets: [String: BadgePreset] = [
    // A badge about 697 × 184 units.
    "catalyst": BadgePreset(word: "CATALYST", capHeight: 96, leadingPadding: 71.5, trailingPadding: 71.5, fileNamePrefix: "Catalyst"),
    // Picked from renders at 136, 120 and 108. BETA's own 136 made a badge 718 units wide that
    // covered the lower half of the magnifier's disc; 108 matched BETA's 570-unit width but set the
    // word visibly smaller than BETA's. 120 gives a badge about 634 × 229.
    "debug": BadgePreset(word: "DEBUG", capHeight: 120, leadingPadding: 79, trailingPadding: 64, fileNamePrefix: "Debug"),
]

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
// Xcode's end caps, relative to where each meets the straight edge at the lozenge's vertical
// centre. The left one is a unit wider than the right one; both are kept as drawn.
let betaLeftCapWidth: CGFloat = 141
let betaLeftCapControlOffset: CGFloat = 80.862
let betaRightCapWidth: CGFloat = 140
let betaRightCapControlOffset: CGFloat = 80.8804
let betaCapCurveControlHeight: CGFloat = 82.066

let canvasSize: CGFloat = 1024

func exitWithUsage(_ message: String? = nil) -> Never {
    if let message {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
    let presetNames = badgePresets.keys.sorted().joined(separator: " | ")
    FileHandle.standardError.write(Data("usage: GenerateBadgeLayers.swift <\(presetNames)> <icon Assets directory> [--cap-height <units>]\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 || arguments.count == 4 else { exitWithUsage() }
guard var preset = badgePresets[arguments[0]] else { exitWithUsage("unknown badge: \(arguments[0])") }
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
if arguments.count == 4 {
    guard arguments[2] == "--cap-height", let capHeightOverride = Double(arguments[3]), capHeightOverride > 0 else {
        exitWithUsage()
    }
    preset = BadgePreset(
        word: preset.word,
        capHeight: CGFloat(capHeightOverride),
        leadingPadding: preset.leadingPadding,
        trailingPadding: preset.trailingPadding,
        fileNamePrefix: preset.fileNamePrefix
    )
}

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
let wordmarkOutlines = glyphOutlines(of: preset.word, in: badgeFont(capHeight: preset.capHeight))
let wordmarkInk = inkBounds(of: wordmarkOutlines)

// The lozenge, sized around the wordmark's ink.
let badgeScale = preset.capHeight / betaCapHeight
let lozengeWidth = wordmarkInk.width + (preset.leadingPadding + preset.trailingPadding) * badgeScale
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

// Place the wordmark's ink the leading padding in from the lozenge's left edge, centred vertically.
// With equal paddings this is the ink centred in the lozenge.
let wordmarkOffsetX = lozengeLeft + preset.leadingPadding * badgeScale + wordmarkInk.width / 2 - wordmarkInk.midX
let wordmarkOffsetY = lozengeCenterY - wordmarkInk.midY

print(String(format: "\"%@\" at cap height %.0f: ink %.1f × %.1f; lozenge %.1f × %.1f, x %.1f–%.1f, y %.1f–%.1f",
             preset.word, preset.capHeight, wordmarkInk.width, wordmarkInk.height,
             lozengeWidth, lozengeBottom - lozengeTop, lozengeLeft, lozengeLeft + lozengeWidth, lozengeTop, lozengeBottom))

let header = """
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by Resources/AppIconTools/GenerateBadgeLayers.swift. Do not edit by hand. -->
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

let lozengeURL = outputDirectory.appendingPathComponent("\(preset.fileNamePrefix)Lozenge.svg")
let wordmarkURL = outputDirectory.appendingPathComponent("\(preset.fileNamePrefix)Wordmark.svg")
try! lozengeDocument.write(to: lozengeURL, atomically: true, encoding: .utf8)
try! wordmarkDocument.write(to: wordmarkURL, atomically: true, encoding: .utf8)
print("wrote \(lozengeURL.path) and \(wordmarkURL.path) — \(wordmarkOutlines.count) glyph outlines")

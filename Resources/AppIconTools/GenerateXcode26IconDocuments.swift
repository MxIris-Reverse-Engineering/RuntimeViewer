#!/usr/bin/env swift

// Regenerates the Xcode 26 variants of the app icon documents.
//
//     swift Resources/AppIconTools/GenerateXcode26IconDocuments.swift [--dry-run]
//
// Run it from the repository root after editing either original, and commit both sides.
//
// Why two documents exist at all: Xcode 26's actool cannot open an Icon Composer 27 document.
// A top-level "features" key makes it fail with `Could not open "AppIconBeta.icon"` and an
// NSPlaceholderArray exception, and it then writes no output at all — no icns, no Assets.car,
// no partial Info.plist. Every other Icon Composer 27 addition (a group's `refractivity` and
// `specular`, a layer's `blend-mode`) it parses and ignores, so "features" is the only key that
// has to go.
//
// So AppIcon.icon and AppIconBeta.icon are the Icon Composer 27 originals — the ones to open and
// edit — and AppIconXcode26.icon and AppIconBetaXcode26.icon are their generated counterparts
// with "features" stripped. The app target's RUNTIME_VIEWER_APP_ICON_NAME selects between them
// by XCODE_VERSION_MAJOR; see Configurations/RuntimeViewerUsingAppKit/Debug.xcconfig.
//
// The stripping is textual rather than a JSON re-serialization, because a round trip through
// JSONSerialization rewrites 0.07 as 0.070000000000000007: every untouched byte would churn on
// every run. The result is parsed afterwards to prove it is still valid JSON.

import Foundation

let fileManager = FileManager.default
let isDryRun = CommandLine.arguments.contains("--dry-run")

struct GenerationFailure: Error, CustomStringConvertible {
    let description: String
}

/// Removes the top-level `"features" : [ … ],` block from an Icon Composer document.
///
/// Icon Composer writes the document with `JSONSerialization`'s pretty printer and sorted keys,
/// so the block is always these exact lines at two-space indentation. A document that has no
/// such block is already an Icon Composer 1.6 document and passes through untouched, which is
/// what makes re-running this script idempotent.
func removingFeatures(from document: String) throws -> String {
    var lines = document.components(separatedBy: "\n")
    guard let openingIndex = lines.firstIndex(where: { $0 == "  \"features\" : [" }) else {
        guard lines.contains(where: { $0.hasPrefix("  \"features\"") }) else { return document }
        throw GenerationFailure(description: "found a \"features\" key in an unexpected shape; refusing to edit")
    }
    guard let closingIndex = lines[openingIndex...].firstIndex(where: { $0 == "  ]," }) else {
        throw GenerationFailure(description: "the \"features\" array is not closed by a `],` line at top level")
    }
    lines.removeSubrange(openingIndex...closingIndex)
    return lines.joined(separator: "\n")
}

func generate(original originalName: String, variant variantName: String) throws {
    let originalURL = URL(fileURLWithPath: "Resources/\(originalName).icon")
    let variantURL = URL(fileURLWithPath: "Resources/\(variantName).icon")

    guard fileManager.fileExists(atPath: originalURL.path) else {
        throw GenerationFailure(description: "missing \(originalURL.path) — run this from the repository root")
    }

    let originalDocument = try String(contentsOf: originalURL.appendingPathComponent("icon.json"), encoding: .utf8)
    let variantDocument = try removingFeatures(from: originalDocument)
    guard let variantData = variantDocument.data(using: .utf8) else {
        throw GenerationFailure(description: "\(variantName): could not encode the stripped document")
    }
    // Proves the textual edit left valid JSON behind, without rewriting any of the bytes it kept.
    _ = try JSONSerialization.jsonObject(with: variantData)

    let strippedFeatures = originalDocument.count - variantDocument.count
    print("\(variantName).icon — \(strippedFeatures == 0 ? "no \"features\" key to strip" : "stripped \(strippedFeatures) bytes of \"features\"")")
    guard !isDryRun else { return }

    if fileManager.fileExists(atPath: variantURL.path) {
        try fileManager.removeItem(at: variantURL)
    }
    try fileManager.copyItem(at: originalURL, to: variantURL)
    try variantData.write(to: variantURL.appendingPathComponent("icon.json"))
}

do {
    try generate(original: "AppIcon", variant: "AppIconXcode26")
    try generate(original: "AppIconBeta", variant: "AppIconBetaXcode26")
    print(isDryRun ? "dry run — nothing written" : "done")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

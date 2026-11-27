// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import QuartzCore
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Settings › Editor › Scope Guides.
///
/// The framework lays the guides out and draws them in colours only its host sets, and its drawing
/// layer starts with all four at alpha 0. So a bridge that only turns the guides on draws every one
/// of them, invisibly, and the switch seems to do nothing. These tests look at the colours the guide
/// layers are actually drawn with.
@Suite("ScopeGuides", .serialized)
@MainActor
struct ScopeGuideTests {
    /// Three nested scopes, each a guide over the lines inside it.
    private static let nestedSource = """
    struct Outer {
        func method() {
            if true {
                let value = 1
                print(value)
            }
        }
    }
    """

    @Test(arguments: ["Default (Light)", "Default (Dark)"])
    func guidesAreDrawnInAVisibleColour(themeName: String) async throws {
        let harness = try SourceEditorTestHarness()
        try harness.applyBuiltInTheme(named: themeName)
        harness.showScopeGuides()
        harness.setSource(Self.nestedSource)

        let guidesLaidOut = await harness.layout { !Self.guideColors(in: harness).isEmpty }
        try #require(guidesLaidOut, "no scope guide was laid out")

        let alphas = Self.guideColors(in: harness).map(\.alpha)
        #expect(alphas.contains { $0 > 0 }, "every guide is drawn at alpha 0: \(alphas)")
    }

    /// The colours every guide segment is drawn with: a gradient's stops, or a shape's fill.
    private static func guideColors(in harness: SourceEditorTestHarness) -> [CGColor] {
        harness.layers(ofClassNamed: "ScopeGuidesDrawingLayer").flatMap { drawingLayer in
            (drawingLayer.sublayers ?? []).flatMap { segmentLayer -> [CGColor] in
                if let gradientLayer = segmentLayer as? CAGradientLayer {
                    return (gradientLayer.colors ?? []).map { $0 as! CGColor }
                }
                if let shapeLayer = segmentLayer as? CAShapeLayer, let fillColor = shapeLayer.fillColor {
                    return [fillColor]
                }
                return []
            }
        }
    }
}

#endif

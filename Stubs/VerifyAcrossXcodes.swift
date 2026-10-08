// Drives one built bridge bundle against one Xcode, in a process of its own.
//
//   VerifyAcrossXcodes <Xcode.app> <RuntimeViewerSourceEditorBridge.bundle>
//
// Run by VerifyAcrossXcodes.sh, which is what supplies the loop over installed Xcodes. One
// process per Xcode is not a convenience: the frameworks are `dlopen`ed and never unloaded, so a
// single process can only ever exercise one version of them.
//
// Compiled by that script together with the bridge's own
// `RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/SourceEditorBridging.swift`, not
// against a copy of the protocol. A copy went stale once — it still listed a removed method, so the
// probe stayed green while the method replacing it was never called on any Xcode. Compiled against
// the real declaration, a renamed or removed requirement stops this file from compiling instead.
// The consequence for whoever changes the bridge: what it newly calls is called here too, in the
// same change (`Stubs/README.md`).
//
// Loads the frameworks the way `SourceEditorLoader` does — by absolute path, in a fixed-point
// loop, with RTLD_GLOBAL — then drives the whole `SourceEditorBridging` surface. Printing "OK" per
// step rather than only at the end is what makes a failure say which call broke.

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: VerifyAcrossXcodes <Xcode.app> <bridge bundle>")
    exit(2)
}
let xcodeURL = URL(fileURLWithPath: CommandLine.arguments[1])
let bundleURL = URL(fileURLWithPath: CommandLine.arguments[2])

/// Answers both of the bridge's callbacks with nothing. Set on the bridge so that its two
/// delegate setters run against every Xcode too; the callbacks themselves need a click or a hover.
final class InertBridgeDelegate: NSObject, SourceEditorBridgingNavigationDelegate, SourceEditorBridgingMinimapLandmarkIconProvider {
    func sourceEditorBridge(_ bridge: SourceEditorBridging, didCommandClickTokenIn characterRange: NSRange) {}

    func sourceEditorBridge(_ bridge: SourceEditorBridging, contextualMenuItemsForTokenIn characterRange: NSRange) -> [NSMenuItem] {
        []
    }

    func sourceEditorBridge(
        _ bridge: SourceEditorBridging,
        minimapIconForLandmarkOfKind kind: SourceEditorBridgingLandmarkKind,
        pointSize: CGFloat
    ) -> NSImage? {
        nil
    }
}

func report(_ message: String) { print("OK   \(message)") }

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(1)
}

// MARK: - The frameworks

let frameworksDirectory = xcodeURL.appending(path: "Contents/SharedFrameworks")
var pendingFrameworkNames = ["SourceEditor", "SourceModel", "SourceModelSupport", "_CodeCompletionFoundation"]

// Their install names are @rpath-relative and they depend on each other, so one that fails a pass
// succeeds a later one. Only a pass that makes no progress is a real failure.
while !pendingFrameworkNames.isEmpty {
    var stillPendingFrameworkNames: [String] = []
    var lastFailureReason = "unknown dlopen failure"
    for frameworkName in pendingFrameworkNames {
        let binaryPath = frameworksDirectory
            .appending(path: "\(frameworkName).framework/Versions/A/\(frameworkName)")
            .path
        if dlopen(binaryPath, RTLD_LAZY | RTLD_GLOBAL) == nil {
            stillPendingFrameworkNames.append(frameworkName)
            lastFailureReason = dlerror().map { String(cString: $0) } ?? lastFailureReason
        }
    }
    if stillPendingFrameworkNames.count == pendingFrameworkNames.count {
        fail("dlopen \(stillPendingFrameworkNames.joined(separator: ", ")): \(lastFailureReason)")
    }
    pendingFrameworkNames = stillPendingFrameworkNames
}
report("frameworks")

// MARK: - The bridge bundle

guard let bundle = Bundle(url: bundleURL) else { fail("no bundle at \(bundleURL.path)") }
do {
    try bundle.loadAndReturnError()
} catch {
    fail("bundle load: \(error.localizedDescription)")
}
report("bundle")

// The cast `SourceEditorLoader` makes: the Objective-C runtime matches the bundle's conformance to
// the protocol by name.
guard let principalClass = bundle.principalClass else { fail("no principal class") }
guard let bridgeClass = principalClass as? SourceEditorBridging.Type else {
    fail("\(principalClass) does not conform to RuntimeViewerSourceEditorBridging")
}
let bridge = bridgeClass.init()
report("bridge \(bridgeClass)")

// MARK: - The surface

let editorView = bridge.editorView
report("editorView \(type(of: editorView))")

// Held here because the bridge holds both weakly.
let inertBridgeDelegate = InertBridgeDelegate()
bridge.navigationDelegate = inertBridgeDelegate
bridge.minimapLandmarkIconProvider = inertBridgeDelegate
report("navigationDelegate + minimapLandmarkIconProvider")

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.contentView = editorView

// All seven on, because each installs a different margin accessory or event consumer, and the
// minimap in particular is the one that reaches Metal.
bridge.applyDisplayOptions(
    showsLineNumbers: true,
    showsFoldingRibbon: true,
    showsStickyHeaders: true,
    showsMinimap: true,
    showsScopeGuides: true,
    showsInvisibles: true,
    showsMarkSeparators: true
)
report("applyDisplayOptions")

let themeURL = frameworksDirectory
    .appending(path: "SourceEditor.framework/Versions/A/Resources/Default (Dark).xccolortheme")
guard let themeDictionary = NSDictionary(contentsOf: themeURL) else {
    fail("no theme at \(themeURL.path)")
}
bridge.applyTheme(
    name: "Default (Dark)",
    dictionary: themeDictionary,
    fontSizeModifier: 0,
    lineNumberFont: .monospacedSystemFont(ofSize: 11, weight: .regular)
)
report("applyTheme (\(themeDictionary.count) keys)")

bridge.applyBackgroundColor(.black)
bridge.applyTopContentInset(52)
report("applyBackgroundColor + applyTopContentInset")

// Both languages, because each resolves a different `SourceModelEditorLanguage` and brings up its
// own language service — and the semantic ranges are what exercise the node type adjuster, whose
// requirement signature is the thing Xcode 27 changed.
let objectiveCSource = """
// MARK: - Probe
@interface NSString (Probe)
- (NSString *)probeValue;
@end
"""
bridge.setSource(
    objectiveCSource,
    languageIdentifier: "objc",
    semanticRanges: [NSValue(range: NSRange(objectiveCSource.range(of: "NSString")!, in: objectiveCSource))],
    semanticNodeTypeNames: ["xcode.syntax.identifier.class"]
)
report("setSource objc")

let swiftSource = """
// MARK: - Probe
public final class ProbeType: NSObject {
    public var probeValue: String { "value" }
}
"""
bridge.setSource(
    swiftSource,
    languageIdentifier: "swift",
    semanticRanges: [NSValue(range: NSRange(swiftSource.range(of: "ProbeType")!, in: swiftSource))],
    semanticNodeTypeNames: ["xcode.syntax.identifier.class"]
)
report("setSource swift")

editorView.layoutSubtreeIfNeeded()
editorView.display()
report("layout + display")

// The Find navigator's reveal: a position lookup in the data source, a selection with a scroll
// placement — `ScrollPlacement` is a resilient enum, so its case travels as an index taken from
// declaration order — and the callout. The run loop turns after each call so whatever they leave
// for it, a scroll or the callout's animation, runs before the step is reported.
guard let probeValueRange = swiftSource.range(of: "probeValue") else { fail("no probeValue in the Swift probe") }
bridge.revealCharacterRange(NSRange(probeValueRange, in: swiftSource))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
report("revealCharacterRange")

// The boundary case of both: an empty range at the very end of the text, so the position lookup is
// asked for the offset one past the last character and the callout for a range with no width.
bridge.revealCharacterRange(NSRange(location: (swiftSource as NSString).length, length: 0))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
report("revealCharacterRange at the end of the text")

print("DONE")

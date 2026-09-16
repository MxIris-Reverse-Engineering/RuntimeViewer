// Drives one built bridge bundle against one Xcode, in a process of its own.
//
//   xcrun swift VerifyAcrossXcodes.swift <Xcode.app> <RuntimeViewerSourceEditorBridge.bundle>
//
// Run by VerifyAcrossXcodes.sh, which is what supplies the loop over installed Xcodes. One
// process per Xcode is not a convenience: the frameworks are `dlopen`ed and never unloaded, so a
// single process can only ever exercise one version of them.
//
// Loads the frameworks the way `SourceEditorLoader` does — by absolute path, in a fixed-point
// loop, with RTLD_GLOBAL — then drives the whole `SourceEditorBridging` surface. Printing "OK" per
// step rather than only at the end is what makes a failure say which call broke.

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: VerifyAcrossXcodes.swift <Xcode.app> <bridge bundle>")
    exit(2)
}
let xcodeURL = URL(fileURLWithPath: CommandLine.arguments[1])
let bundleURL = URL(fileURLWithPath: CommandLine.arguments[2])

/// Declared here rather than imported: the app and the bundle meet through the Objective-C
/// runtime, which matches this protocol to the bundle's conformance by name.
@objc(RuntimeViewerSourceEditorBridging)
protocol SourceEditorBridging: NSObjectProtocol {
    var editorView: NSView { get }
    func setSource(_ source: String, languageIdentifier: String, semanticRanges: [NSValue], semanticNodeTypeNames: [String])
    func applyBackgroundColor(_ backgroundColor: NSColor)
    func applyDisplayOptions(
        showsLineNumbers: Bool,
        showsFoldingRibbon: Bool,
        showsStickyHeaders: Bool,
        showsMinimap: Bool,
        showsScopeGuides: Bool,
        showsInvisibles: Bool,
        showsMarkSeparators: Bool
    )
    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont)
    func applyTopContentInset(_ topInset: CGFloat)
    func scrollToCharacterIndex(_ characterIndex: Int)
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

guard let bridgeClass = bundle.principalClass as? NSObject.Type else { fail("no principal class") }
guard let bridge = bridgeClass.init() as? SourceEditorBridging else {
    fail("\(bridgeClass) does not conform to RuntimeViewerSourceEditorBridging")
}
report("bridge \(bridgeClass)")

// MARK: - The surface

let editorView = bridge.editorView
report("editorView \(type(of: editorView))")

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

print("DONE")

import AppKit
import QuartzCore
import SourceEditor

/// Loads the bridge bundle the way the app does and puts its editor view somewhere a layout
/// pass will actually run.
///
/// Driving the bridge rather than a bare `SourceEditorView` is the point: the ordering under
/// test lives in `SourceEditorBridge.setSource`, and a test that built its own view would pass
/// no matter what that method does.
@MainActor
final class SourceEditorTestHarness {
    /// Whether Xcode's private frameworks were there to link against at load time.
    ///
    /// The test bundle weak-links them (`-weak_framework`), so a machine without Xcode loads
    /// the bundle fine and simply finds the classes missing — which is a skip, not a failure.
    /// Reading a class by its mangled Swift name avoids touching a `SourceEditor` type from
    /// this property, which would fault the missing symbols in before the check could run.
    ///
    /// `nonisolated` because `.enabled(if:)` evaluates its condition in a `Sendable` closure,
    /// which cannot reach a main-actor-isolated property. Asking the Objective-C runtime for a
    /// class is threadsafe, so there is nothing to isolate.
    nonisolated static var isFrameworkLoaded: Bool {
        NSClassFromString("_TtC12SourceEditor16SourceEditorView") != nil
    }

    private let bridge: SourceEditorBridging
    private let window: NSWindow

    /// The view's folding controller, which is where the state under test lives.
    let foldingController: FoldingController

    init() throws {
        let bundleURL = Bundle(for: BundleAnchor.self)
            .bundleURL
            .deletingLastPathComponent()
            .appending(path: "RuntimeViewerSourceEditorBridge.bundle")

        guard let bundle = Bundle(url: bundleURL) else {
            throw HarnessError.bridgeBundleMissing(bundleURL)
        }
        guard bundle.load() else {
            throw HarnessError.bridgeBundleFailedToLoad(bundleURL)
        }
        guard let principalClass = bundle.principalClass as? NSObject.Type,
              let bridge = principalClass.init() as? SourceEditorBridging
        else {
            throw HarnessError.bridgePrincipalClassUnusable(bundle.principalClass)
        }
        self.bridge = bridge

        guard let editorView = bridge.editorView as? SourceEditorView else {
            throw HarnessError.editorViewUnexpectedType(type(of: bridge.editorView))
        }
        self.foldingController = editorView.foldingController

        // Off-screen is enough — measured. What the crash needs is a layer-backed view whose
        // layoutSublayers(of:) runs inside a CoreAnimation transaction, not a visible window.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editorView
        window.orderFront(nil)
    }

    func setSource(_ source: String) {
        bridge.setSource(source, languageIdentifier: "swift", semanticRanges: [], semanticNodeTypeNames: [])
    }

    /// Forces the layout the crash happens inside.
    ///
    /// `layoutSubtreeIfNeeded()` alone is not enough: the trap is reached from
    /// `NSViewBackingLayer.layoutSublayers`, which runs when the CoreAnimation transaction
    /// commits. The short run-loop spin lets a transaction the framework scheduled itself land
    /// as well.
    func layout() {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private final class BundleAnchor {}

    enum HarnessError: Error, CustomStringConvertible {
        case bridgeBundleMissing(URL)
        case bridgeBundleFailedToLoad(URL)
        case bridgePrincipalClassUnusable(AnyClass?)
        case editorViewUnexpectedType(Any.Type)

        var description: String {
            switch self {
            case .bridgeBundleMissing(let url):
                "no bridge bundle beside the test bundle at \(url.path)"
            case .bridgeBundleFailedToLoad(let url):
                "the bridge bundle at \(url.path) failed to load"
            case .bridgePrincipalClassUnusable(let principalClass):
                "the bridge bundle's principal class \(principalClass.map(String.init(describing:)) ?? "<nil>") is not a SourceEditorBridging"
            case .editorViewUnexpectedType(let type):
                "the bridge handed back a \(type) rather than a SourceEditorView"
            }
        }
    }
}

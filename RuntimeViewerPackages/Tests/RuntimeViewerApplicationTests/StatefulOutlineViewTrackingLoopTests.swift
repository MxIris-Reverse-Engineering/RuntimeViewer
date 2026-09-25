import AppKit
import Foundation
import Testing
import RuntimeViewerUI

/// Regression suite for `StatefulOutlineView` staying on AppKit's mouse
/// tracking loop.
///
/// History: from macOS 27 every `NSTableView` handles the mouse with gesture
/// recognizers, whatever SDK the app links against, and their drag handler
/// moves the selection with the pointer only when `allowsMultipleSelection`
/// is on. In the single-selection sidebar lists, pressing a row and dragging
/// stopped selecting the rows under the pointer. `StatefulOutlineView`
/// overrides `mouseDown(with:)`, which makes AppKit install none of those
/// recognizers and keep macOS 26's tracking loop.
///
/// A posted drag is the wrong seam for this: it needs a key window, which a
/// test process cannot count on. The suite pins the decision AppKit takes
/// when the view is created instead — which of its own gesture recognizers,
/// named `NSTableView.*`, it attaches. The names are private, so a plain
/// `NSOutlineView` is checked first: if a later macOS renames or drops them,
/// the suite fails on that canary rather than passing without checking
/// anything, and the fallback has to be verified again by hand. Before
/// macOS 27 tables have no gesture path to fall back from, so the test is
/// skipped there.
@Suite("StatefulOutlineViewTrackingLoop")
@MainActor
struct StatefulOutlineViewTrackingLoopTests {
    @available(macOS 26.0, *)
    private static func tableGestureRecognizerNames(of outlineView: NSOutlineView) -> [String] {
        outlineView.gestureRecognizers
            .compactMap(\.name)
            .filter { $0.hasPrefix("NSTableView.") }
    }

    @available(macOS 27.0, *)
    @Test("installs none of the table gesture recognizers a plain outline view gets")
    func installsNoTableGestureRecognizers() {
        let plainOutlineViewRecognizerNames = Self.tableGestureRecognizerNames(of: NSOutlineView())
        #expect(
            plainOutlineViewRecognizerNames.contains("NSTableView.mousePanGestureRecognizer"),
            "a plain NSOutlineView no longer reports the drag recognizer; found \(plainOutlineViewRecognizerNames)"
        )

        let statefulOutlineViewRecognizerNames = Self.tableGestureRecognizerNames(of: StatefulOutlineView())
        #expect(
            statefulOutlineViewRecognizerNames.isEmpty,
            "StatefulOutlineView is on the gesture path again; found \(statefulOutlineViewRecognizerNames)"
        )
    }
}

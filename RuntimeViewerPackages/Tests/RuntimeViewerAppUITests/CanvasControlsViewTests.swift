#if os(macOS)

import AppKit
import Testing
@testable import RuntimeViewerUI

/// `CanvasControlsView`: the zoom level as a whole percentage, the zoom
/// buttons greyed out at the ends of the range, the hand tool's toggle, and
/// Preview's shortcuts on the zoom buttons.
@MainActor
@Suite("CanvasControlsView")
struct CanvasControlsViewTests {
    @Test("the zoom level shows the magnification as a whole percentage")
    func zoomLevelTextRoundsToWholePercent() {
        #expect(CanvasControlsView.zoomLevelText(for: 0.3555) == "36%")
        #expect(CanvasControlsView.zoomLevelText(for: 1) == "100%")

        let controlsView = CanvasControlsView(frame: .zero)
        controlsView.magnification = 2.5

        #expect(controlsView.zoomLevelButton.title == "250%")
    }

    @Test("zoom out greys out at the smallest magnification")
    func zoomOutIsDisabledAtMinimumMagnification() {
        let controlsView = CanvasControlsView(frame: .zero)
        controlsView.magnificationRange = 0.1 ... 4

        controlsView.magnification = 0.1

        #expect(!controlsView.zoomOutButton.isEnabled)
        #expect(controlsView.zoomInButton.isEnabled)
    }

    @Test("zoom in greys out at the largest magnification")
    func zoomInIsDisabledAtMaximumMagnification() {
        let controlsView = CanvasControlsView(frame: .zero)
        controlsView.magnificationRange = 0.1 ... 4

        controlsView.magnification = 4

        #expect(controlsView.zoomOutButton.isEnabled)
        #expect(!controlsView.zoomInButton.isEnabled)

        controlsView.magnification = 1

        #expect(controlsView.zoomOutButton.isEnabled)
        #expect(controlsView.zoomInButton.isEnabled)
    }

    @Test("the hand tool turns on and off with each click")
    func handToolToggles() {
        let controlsView = CanvasControlsView(frame: .zero)

        #expect(controlsView.handToolButton.state == .off)
        controlsView.handToolButton.performClick(nil)
        #expect(controlsView.handToolButton.state == .on)
        controlsView.handToolButton.performClick(nil)
        #expect(controlsView.handToolButton.state == .off)
    }

    @Test("the zoom buttons answer ⌘=, ⌘−, ⌘0 and ⌘9")
    func zoomShortcuts() {
        let controlsView = CanvasControlsView(frame: .zero)

        #expect(controlsView.zoomInButton.keyEquivalent == "=")
        #expect(controlsView.zoomOutButton.keyEquivalent == "-")
        #expect(controlsView.zoomLevelButton.keyEquivalent == "0")
        #expect(controlsView.zoomToFitButton.keyEquivalent == "9")
        let buttons = [controlsView.zoomInButton, controlsView.zoomOutButton, controlsView.zoomLevelButton, controlsView.zoomToFitButton]
        #expect(buttons.allSatisfy { $0.keyEquivalentModifierMask == .command })
    }
}

#endif

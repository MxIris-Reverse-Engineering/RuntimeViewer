import AppKit
import RuntimeViewerUI

/// The loading indicator `BaseViewController` lays over its view: the system spinner, centred in
/// the part of the view the toolbar leaves visible.
///
/// Behind the spinner it shows frosted glass before macOS 26 and nothing from macOS 26 on, where
/// panes sit on glass that no material matches. A `backgroundColor` replaces either: the content
/// panes give it the editor's background, which turns it into an opaque plate over the whole
/// pane — minimap, gutter and the strip under the toolbar included — the way Xcode's editor looks
/// while it opens a generated interface.
final class CommonLoadingView: XiblessView {
    /// Whether the spinner is up. It changes only when set: `BaseViewController` drives it from
    /// `delayedLoading` alone, so a pane rebound to a new ViewModel keeps showing what it showed
    /// until that ViewModel reports.
    var isRunning = false {
        didSet {
            isHidden = !isRunning
            if isRunning {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
        }
    }

    private let progressIndicator = NSProgressIndicator()

    /// The frosted glass, before macOS 26 only. It covers the safe area, as it always has.
    private let backgroundEffectView: NSVisualEffectView? = {
        if #available(macOS 26.0, *) {
            nil
        } else {
            NSVisualEffectView()
        }
    }()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)

        // Hidden until the first report. A visible view here, even a transparent one, would
        // swallow every click meant for the pane underneath.
        isHidden = true

        progressIndicator.do {
            $0.style = .spinning
            $0.controlSize = .regular
            $0.isIndeterminate = true
            $0.isDisplayedWhenStopped = false
            $0.sizeToFit()
        }

        if let backgroundEffectView {
            hierarchy {
                backgroundEffectView
            }
            backgroundEffectView.snp.makeConstraints { make in
                make.edges.equalTo(safeAreaLayoutGuide)
            }
        }

        hierarchy {
            progressIndicator
        }

        // Centred in the safe area rather than the bounds: the view runs up under the toolbar so
        // that a painted background covers that strip too, and the spinner belongs in the middle
        // of what the toolbar leaves visible.
        progressIndicator.snp.makeConstraints { make in
            make.center.equalTo(safeAreaLayoutGuide)
        }
    }

    /// Runs whenever the background colour changes and whenever the appearance does — everything
    /// the frosted glass and the spinner's appearance depend on.
    override func updateLayer() {
        super.updateLayer()

        // The painted background is the view's own layer, beneath its subviews, so the glass has
        // to step aside for it rather than blur over it. Assigned only on a change: this runs
        // inside the display pass.
        if let backgroundEffectView, backgroundEffectView.isHidden != (backgroundColor != nil) {
            backgroundEffectView.isHidden = backgroundColor != nil
        }
        updateProgressIndicatorAppearance()
    }

    /// Draws the spinner light on a dark background and dark on a light one, whatever the
    /// window's appearance. A custom theme can pair a dark editor background with the light
    /// appearance, or the reverse, and the spinner — which otherwise follows the appearance —
    /// would then be grey on grey. Without a background it simply follows the appearance.
    private func updateProgressIndicatorAppearance() {
        var backgroundLuma: CGFloat?
        if let backgroundColor {
            // The theme's colours are dynamic; resolve this one the way the layer draws it.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let sRGBColor = backgroundColor.usingColorSpace(.sRGB) else { return }
                backgroundLuma = 0.2126 * sRGBColor.redComponent + 0.7152 * sRGBColor.greenComponent + 0.0722 * sRGBColor.blueComponent
            }
        }
        let progressIndicatorAppearance = backgroundLuma.flatMap { NSAppearance(named: $0 < 0.5 ? .darkAqua : .aqua) }
        // Assigned only on a change: this runs inside the display pass.
        guard progressIndicator.appearance?.name != progressIndicatorAppearance?.name else { return }
        progressIndicator.appearance = progressIndicatorAppearance
    }
}

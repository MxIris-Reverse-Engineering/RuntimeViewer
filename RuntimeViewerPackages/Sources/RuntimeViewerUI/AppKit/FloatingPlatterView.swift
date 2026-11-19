#if os(macOS)

import AppKit
import SnapKit

/// A rounded plate that controls and text float on over a canvas, as the
/// controls of a map do: Liquid Glass (`NSGlassEffectView`) from macOS 26 on,
/// a translucent HUD material before it. The plate takes its size from its
/// content view, which it pins to its edges.
public final class FloatingPlatterView: NSView {
    /// What the plate holds, laid out edge to edge inside it.
    public var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            oldValue?.removeFromSuperview()
            installContentView()
        }
    }

    private let cornerRadius: CGFloat

    /// The glass, or the material view before macOS 26.
    private let backgroundView: NSView

    public init(cornerRadius: CGFloat = 8) {
        self.cornerRadius = cornerRadius
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            backgroundView = glassView
        } else {
            let materialView = NSVisualEffectView()
            materialView.material = .hudWindow
            materialView.blendingMode = .withinWindow
            materialView.state = .active
            materialView.wantsLayer = true
            materialView.layer?.cornerRadius = cornerRadius
            materialView.layer?.masksToBounds = true
            backgroundView = materialView
        }
        super.init(frame: .zero)
        addSubview(backgroundView)
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installContentView() {
        guard let contentView else { return }
        if #available(macOS 26.0, *), let glassView = backgroundView as? NSGlassEffectView {
            glassView.contentView = contentView
        } else {
            backgroundView.addSubview(contentView)
        }
        contentView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}

#endif

import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerArchitectures
import DependenciesMacros

/// What the sidebar's navigation transition puts behind its sliding view controllers.
///
/// They need *some* opaque backdrop or the two lists show through each other. The pages themselves
/// are transparent so that, at rest, they sit directly on the split view item's glass.
enum NavigationTransitionBackdrop {
    /// A `GlassEffectReplicaView` under each page: a glass that copies the enclosing sidebar glass
    /// and shares its backdrop group, so it renders exactly like the sidebar around it.
    case glassReplica
    case color(NSColor)
    case material(NSVisualEffectView.Material)
}

/// The sidebar navigation controller's delegate: inserts a ``SidebarTransitionBackdrop`` under both
/// pages when a push / pop starts and removes it when the transition completes, so the pages are
/// opaque exactly while they slide and transparent the rest of the time.
///
/// From macOS 27 the backdrop is a `GlassEffectReplicaView`, measured pixel-identical to the
/// sidebar around it whether the window is key, moved or resized. On macOS 26 the transition keeps
/// painting `windowBackgroundColor`, which matched that release's glass well enough that nothing
/// else was needed. The other candidates were measured against the settled sidebar — rgb(40, 40, 42) at one window position and rgb(39, 39, 42) at another, the shift
/// coming from the glass's desktop-tint layer sampling whatever the window covers:
/// `underPageBackgroundColor` is the closest constant, and no `NSVisualEffectView` material matches,
/// because nesting one inside the sidebar's glass blends twice, so they land either side of the target
/// rather than on it (`titlebar` / `menu` / `popover` / `sidebar` all render rgb(45, 45, 47);
/// `headerView` / `sheet` / `windowBackground` / `contentBackground` all render rgb(36, 36, 38)).
/// Background: `Documentations/ResolvedIssues/2026-09-18-sidebar-transition-backdrop-glass-replica.md`.
@MainActor
final class NavigationTransitionBackdropController: NSObject, NSNavigationControllerDelegate {
    var selectedBackdrop: NavigationTransitionBackdrop {
        if #available(macOS 27.0, *) {
            return .glassReplica
        } else {
            return .color(.windowBackgroundColor)
        }
    }

    // MARK: - NSNavigationControllerDelegate

    func navigationController(_ navigationController: NSNavigationController, willShow viewController: NSViewController) {
        guard #available(macOS 26.0, *) else { return }
        guard let coordinator = navigationController.transitionCoordinator,
              let fromViewController = coordinator.viewController(forKey: .from),
              let toViewController = coordinator.viewController(forKey: .to)
        else { return }

        switch selectedBackdrop {
        case .glassReplica:
            let fromBackdropView = NavigationTransitionBackdropController.installTransitionBackdropView(GlassEffectReplicaView(), in: fromViewController.view)
            let toBackdropView = NavigationTransitionBackdropController.installTransitionBackdropView(GlassEffectReplicaView(), in: toViewController.view)
            coordinator.animate { _ in } completion: { _ in
                fromBackdropView.removeFromSuperview()
                toBackdropView.removeFromSuperview()
            }
        case .color(let backdropColor):
            let fromOriginalBackgroundColor = fromViewController.view.backgroundColor
            let toOriginalBackgroundColor = toViewController.view.backgroundColor
            coordinator.animate { _ in
                fromViewController.view.backgroundColor = backdropColor
                toViewController.view.backgroundColor = backdropColor
            } completion: { _ in
                fromViewController.view.backgroundColor = fromOriginalBackgroundColor
                toViewController.view.backgroundColor = toOriginalBackgroundColor
            }
        case .material(let backdropMaterial):
            let fromBackdropView = NavigationTransitionBackdropController.installTransitionBackdropView(NavigationTransitionBackdropController.makeMaterialBackdropView(backdropMaterial), in: fromViewController.view)
            let toBackdropView = NavigationTransitionBackdropController.installTransitionBackdropView(NavigationTransitionBackdropController.makeMaterialBackdropView(backdropMaterial), in: toViewController.view)
            coordinator.animate { _ in } completion: { _ in
                fromBackdropView.removeFromSuperview()
                toBackdropView.removeFromSuperview()
            }
        }
    }

    func navigationController(_ navigationController: NSNavigationController, didShow viewController: NSViewController) {
        guard #available(macOS 26.0, *) else { return }
        navigationController.view.needsDisplay = true
    }

    private static func makeMaterialBackdropView(_ material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let backdropView = NSVisualEffectView()
        backdropView.material = material
        backdropView.blendingMode = .behindWindow
        backdropView.state = .followsWindowActiveState
        return backdropView
    }

    /// Puts `backdropView` under everything in `containerView`, filling it, and hands it back so the
    /// completion can remove it.
    @discardableResult
    private static func installTransitionBackdropView<BackdropView: NSView>(_ backdropView: BackdropView, in containerView: NSView) -> BackdropView {
        backdropView.frame = containerView.bounds
        backdropView.autoresizingMask = [.width, .height]
        containerView.addSubview(backdropView, positioned: .below, relativeTo: containerView.subviews.first)
        return backdropView
    }
}

extension NSView {
    /// AppKitPlus's `NSView (Appearance).backgroundColor`, reached through key-value coding because
    /// the category header is framework-internal.
    var backgroundColor: NSColor? {
        set { setValue(newValue, forKey: "backgroundColor") }
        get { value(forKey: "backgroundColor") as? NSColor }
    }
}

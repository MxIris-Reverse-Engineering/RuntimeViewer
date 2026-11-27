import Foundation
import Dependencies
import RuntimeViewerArchitectures
import RuntimeViewerAppCore
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// The content pane's render stage: themes each interface `ContentTextViewModel` prepares, on a
/// background queue, and again whenever the theme changes (proposal `app-core-without-ui-models`). The
/// view model knows no theme; the views own this.
///
/// `renderedText` is cold: nothing is themed until it is subscribed, so the SourceEditor pane, which
/// draws the semantic runs itself and reads only `theme`, builds no attributed string at all.
@MainActor
public final class ContentTextRenderer {
    /// An interface and its text in the theme.
    public struct RenderedText {
        public let interface: ContentInterface
        public let attributedString: NSAttributedString
    }

    /// The theme the pane is drawn in.
    public let theme: Driver<ResolvedTheme>

    /// Each interface in the current theme, again on every theme change; a newer interface or theme
    /// drops a build still under way.
    public let renderedText: Driver<RenderedText>

    /// True from 100 ms into a build until it is delivered — the pane's loading plate for a theme-only
    /// change (⌘+), which the view model does not see. A new interface's build is inside the view
    /// model's own loading, which lasts until the view reports the interface displayed.
    public let delayedRendering: Driver<Bool>

    /// Whether a build is under way, without the delay; what `delayedRendering` is made from, which a
    /// test watches.
    package let isRendering: Driver<Bool>

    /// - Parameters:
    ///   - themes: the themes to draw in; by default the settings' theme
    ///     (`resolvedThemeStream`), on every platform since the settings persist there too.
    ///   - isDimmed: whether the pane draws in the theme of an editor pane without the focus
    ///     (`ResolvedTheme.dimmedForUnfocusedEditorPane()`, proposal `dim-unfocused-editor-panes`);
    ///     never by default. A change re-themes the pane as a theme change does.
    public init(interfaces: Driver<ContentInterface>, themes: Observable<ResolvedTheme>? = nil, isDimmed: Driver<Bool> = .just(false)) {
        let themeObservable: Observable<ResolvedTheme>
        if let themes {
            themeObservable = themes
        } else {
            // The shared stream multicasts a single `Observable.tracking` chain across every document,
            // so editing a custom preset rebuilds `ResolvedTheme` once, not once per open document.
            @Dependency(\.resolvedThemeStream) var resolvedThemeStream
            themeObservable = resolvedThemeStream.observable
        }
        let sharedThemes = Observable
            .combineLatest(themeObservable, isDimmed.asObservable().distinctUntilChanged()) { theme, isDimmed in
                isDimmed ? theme.dimmedForUnfocusedEditorPane() : theme
            }
            .share(replay: 1, scope: .whileConnected)
        theme = sharedThemes.asDriver(onErrorDriveWith: .empty())

        let rendering = ActivityIndicator()
        // One scheduler for the renderer's lifetime: the convenience initializer allocates a fresh
        // DispatchQueue, so making one per build would churn a queue per emission.
        let renderScheduler = ConcurrentDispatchQueueScheduler(qos: .userInitiated)
        renderedText = Observable
            .combineLatest(interfaces.asObservable(), sharedThemes)
            .flatMapLatest { interface, theme -> Observable<RenderedText> in
                Observable.just(())
                    .observe(on: renderScheduler)
                    .map { RenderedText(interface: interface, attributedString: interface.attributedString(themedWith: theme)) }
                    .trackActivity(rendering)
            }
            .asDriver(onErrorDriveWith: .empty())
        isRendering = rendering.asDriver()
        delayedRendering = isRendering.delayingTrue(by: .milliseconds(100))
    }
}

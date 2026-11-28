// See SourceEditorBridgeProvider.swift for when this compiles.
#if RUNTIME_VIEWER_SOURCE_EDITOR

import UIKit
import Observation
import Dependencies
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerSettings
import RuntimeViewerSourceEditorBridge

/// A runtime object's interface in the reconstructed SourceEditor: the iOS counterpart of the
/// macOS app's controller of the same name, binding the same `ContentTextViewModel` as
/// `ContentTextViewController`, which `ContentCoordinator` uses instead where this build carries no
/// SourceEditor.
///
/// What the UIKit build of the frameworks can show: the text with its semantic runs, the settings'
/// theme, the Settings › Editor options it has, the system find navigator (the magnifying glass in
/// the navigation bar, and ⌘F with a keyboard) and the reader's place when an object comes back. Not
/// the comment tags, inline expansions or jumps of the macOS pane: the frameworks' UIKit build has
/// no folding or gaps, and nothing on iOS follows a selection route yet.
final class ContentSourceEditorViewController: UIKitViewController<ContentTextViewModel> {
    @Dependency(\.sourceEditorBridgeProvider) private var sourceEditorBridgeProvider

    @Dependency(\.settings) private var settings

    /// Nil only when the provider has no bridge to give, which `ContentCoordinator` has ruled out
    /// before making this controller; the pane then stays empty rather than failing.
    private lazy var bridge: SourceEditorBridging? = sourceEditorBridgeProvider.makeBridge()

    /// Each interface once its text is in the editor, which ends the view model's loading for it.
    private let interfaceDisplayedRelay = PublishRelay<ContentInterface.ID>()

    /// The theme the renderer last delivered, applied again when the appearance changes.
    private var currentTheme: ResolvedTheme?

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let bridge else { return }

        hierarchy {
            bridge.editorView
        }

        // The safe area, as the text view's page does: the editor view is a scroll view that
        // adjusts its own content insets, and the page's background covers what lies outside it.
        bridge.editorView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.bridge?.showFindInterface(query: "", pattern: .contains, isCaseSensitive: false)
            }
        )

        followDisplayOptions()

        // The framework's own colours — the invisibles, markup, what the settings' theme has no
        // key for — come from its light or dark default, picked by the appearance.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (viewController: Self, _: UITraitCollection) in
            viewController.applyCurrentTheme()
        }
    }

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: .empty(),
            runtimeObjectOpenedInNewTab: .empty(),
            interfaceDisplayed: interfaceDisplayedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        let interfaceLanguage = viewModel.interfaceLanguage
        Driver.combineLatest(output.interface, viewModel.$runtimeObject.asDriver())
            .driveOnNext { [weak self] interface, runtimeObject in
                guard let self else { return }
                show(
                    interface,
                    languageIdentifier: SourceEditorSourceConversion.languageIdentifier(
                        for: runtimeObject.kind,
                        interfaceLanguage: interfaceLanguage
                    )
                )
            }
            .disposed(by: rx.disposeBag)

        // The editor colours the semantic runs itself and takes only the theme from the renderer,
        // whose themed text it never asks for.
        let renderer = ContentTextRenderer(interfaces: output.interface)
        renderer.theme.driveOnNext { [weak self] theme in
            guard let self else { return }
            currentTheme = theme
            applyCurrentTheme()
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectName.drive(navigationItem.rx.title).disposed(by: rx.disposeBag)
    }

    private func show(_ interface: ContentInterface, languageIdentifier: String) {
        defer { interfaceDisplayedRelay.accept(interface.id) }
        guard let bridge else { return }
        let (semanticRanges, nodeTypeNames) = SourceEditorSourceConversion.semanticRuns(of: interface.semanticString)
        bridge.setSource(
            interface.string,
            languageIdentifier: languageIdentifier,
            semanticRanges: semanticRanges,
            semanticNodeTypeNames: nodeTypeNames,
            commentDecorations: nil,
            restoresScrollPosition: true
        )
    }

    private func applyCurrentTheme() {
        guard let bridge else { return }
        let isDark = traitCollection.userInterfaceStyle == .dark
        let baseThemeName = isDark ? "Default (Dark)" : "Default (Light)"
        guard let baseTheme = sourceEditorBridgeProvider.builtInThemeDictionary(named: baseThemeName) else { return }

        // In this page's trait collection: a dynamic colour of the theme resolves against the
        // current one when the conversion reads its components.
        var dictionary = baseTheme
        traitCollection.performAsCurrent {
            if let currentTheme,
               let convertedTheme = SourceEditorThemeConversion.themeDictionary(from: currentTheme, basedOn: baseTheme, baseThemeDimming: nil) {
                dictionary = convertedTheme
            }
        }

        // The gutter has no theme key of its own; the text's font keeps a number level with its row.
        let lineNumberFont = currentTheme?.font(for: .standard) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        bridge.applyTheme(name: baseThemeName, dictionary: dictionary, fontSizeModifier: 0, lineNumberFont: lineNumberFont)

        // The theme's background around the editor too, as the text view's page does: behind the
        // navigation bar and beside the home indicator, outside the safe area the editor fills.
        if let backgroundColor = currentTheme?.backgroundColor {
            bridge.applyBackgroundColor(backgroundColor)
            view.backgroundColor = backgroundColor
        }
    }

    /// Applies Settings › Editor now and again whenever it changes, as the app's
    /// `AppearanceController` follows the appearance setting.
    private func followDisplayOptions() {
        guard let bridge else { return }
        withObservationTracking {
            bridge.applyDisplayOptions(from: settings.editor)
        } onChange: { [weak self] in
            // Observation calls this before the change commits; apply the new value once it has.
            Task { @MainActor [weak self] in
                guard let self else { return }
                followDisplayOptions()
            }
        }
    }
}

#endif

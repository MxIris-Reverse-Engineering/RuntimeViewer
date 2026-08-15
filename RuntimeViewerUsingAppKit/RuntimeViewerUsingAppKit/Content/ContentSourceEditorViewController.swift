import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

/// Content pane backed by Xcode's editor instead of `NSTextView`.
///
/// It binds the same `ContentTextViewModel` as `ContentTextViewController`, so the two are
/// interchangeable and the fallback costs nothing beyond choosing a different class.
///
/// **Syntax coloring here is lexical, not semantic.** The framework tokenizes the plain text
/// itself from a language specification, whereas `ContentTextViewController` renders the
/// generator's semantic tokens, which know each identifier's real type. Feeding those tokens
/// in instead requires reconstructing `SourceEditorLanguageService`, which is not done yet.
/// Jump targets are unaffected: they are read from the generator's `.link` attributes below,
/// never from the framework's tokenizer.
final class ContentSourceEditorViewController: UXKitViewController<ContentTextViewModel> {
    override var acceptsFirstResponder: Bool { true }

    override var shouldDisplayCommonLoading: Bool { true }

    @Dependency(\.sourceEditorLoader) private var sourceEditorLoader

    private lazy var bridge: SourceEditorBridging? = sourceEditorLoader.makeBridge()

    /// The string currently handed to the editor. ⌘-click reports a UTF-16 range into this
    /// very string, so the generator's `.link` attribute can be read straight off it.
    private var displayedAttributedString: NSAttributedString?

    private let jumpToDefinitionRelay = PublishRelay<RuntimeObject>()

    private let openInNewTabRelay = PublishRelay<RuntimeObject>()

    /// `viewDidChangeEffectiveAppearance` is an `NSView` callback, not an `NSViewController`
    /// one, so the appearance switch has to be observed rather than overridden.
    private var effectiveAppearanceObservation: NSKeyValueObservation?

    /// Held because the theme has to be re-applied on an appearance change too, and that
    /// notification carries no theme with it.
    private var currentTheme: ThemeProfile?

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let bridge else { return }
        bridge.navigationDelegate = self

        effectiveAppearanceObservation = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.applyCurrentTheme()
            }
        }

        contentView.hierarchy {
            bridge.editorView
        }

        bridge.editorView.snp.makeConstraints { make in
            make.top.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: jumpToDefinitionRelay.asSignal(),
            runtimeObjectOpenedInNewTab: openInNewTabRelay.asSignal()
        )
        let output = viewModel.transform(input)

        Driver.combineLatest(output.attributedString, viewModel.$runtimeObject.asDriver())
            .driveOnNext { [weak self] attributedString, runtimeObject in
                guard let self else { return }
                displayedAttributedString = attributedString
                bridge?.setSource(attributedString, languageIdentifier: Self.languageIdentifier(for: runtimeObject.kind))
            }
            .disposed(by: rx.disposeBag)

        output.theme.driveOnNext { [weak self] theme in
            guard let self else { return }
            currentTheme = theme
            applyCurrentTheme()
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectNotFound.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            var configuration = HUDView.Configuration.standard()
            configuration.image = SFSymbols(systemName: .questionmark, pointSize: 80, weight: .light).nsuiImgae
            view.window?.showHUD(with: configuration)
        }
        .disposed(by: rx.disposeBag)
    }

    /// Renders the app's configured theme into `.xccolortheme` form, using the framework's own
    /// theme as the base so the many keys `ThemeProfile` has no opinion about stay valid.
    ///
    /// The base still tracks light/dark, which matters for exactly those unmapped keys —
    /// invisibles, current-line highlight, markup colors.
    private func applyCurrentTheme() {
        guard let bridge else { return }
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let baseThemeName = isDark ? "Default (Dark)" : "Default (Light)"
        guard let baseTheme = sourceEditorLoader.builtInThemeDictionary(named: baseThemeName) else { return }

        let dictionary = currentTheme.flatMap {
            SourceEditorThemeConversion.themeDictionary(from: $0, basedOn: baseTheme)
        } ?? baseTheme

        bridge.applyTheme(name: baseThemeName, dictionary: dictionary, fontSizeModifier: 0)

        // The theme covers the text area; these cover everything around it — the area past
        // the end of the document, and the container behind the editor.
        if let backgroundColor = currentTheme?.backgroundColor {
            bridge.applyBackgroundColor(backgroundColor)
            (contentView as? UXView)?.backgroundColor = backgroundColor
        }
    }

    private static func languageIdentifier(for kind: RuntimeObjectKind) -> String {
        switch kind {
        case .swift: "swift"
        case .objc, .c: "objc"
        }
    }
}

// MARK: - Navigation

extension ContentSourceEditorViewController: SourceEditorBridgingNavigationDelegate {
    func sourceEditorBridge(_ bridge: SourceEditorBridging, didCommandClickTokenIn characterRange: NSRange) {
        guard let displayedAttributedString,
              characterRange.location < displayedAttributedString.length,
              let runtimeObject = displayedAttributedString
                  .attributes(at: characterRange.location, effectiveRange: nil)[.link] as? RuntimeObject
        else { return }

        // Same split as the NSTextView path: ⌘-click jumps in place, ⌘⇧-click opens a tab.
        if NSEvent.modifierFlags.contains(.shift) {
            openInNewTabRelay.accept(runtimeObject)
        } else {
            jumpToDefinitionRelay.accept(runtimeObject)
        }
    }
}

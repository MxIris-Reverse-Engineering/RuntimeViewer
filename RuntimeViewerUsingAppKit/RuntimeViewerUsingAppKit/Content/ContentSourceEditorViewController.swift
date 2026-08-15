import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import RuntimeViewerUI
import Semantic

/// Content pane backed by Xcode's editor instead of `NSTextView`.
///
/// It binds the same `ContentTextViewModel` as `ContentTextViewController`, so the two are
/// interchangeable and the fallback costs nothing beyond choosing a different class.
///
/// The editor parses the plain text itself and so cannot tell what an identifier is; the
/// generator's semantic runs are passed alongside the text to correct that parse, through the
/// framework's own node-type adjuster. Coloring therefore comes out semantic, and so do token
/// ranges — which is what ⌘-click reads.
final class ContentSourceEditorViewController: UXKitViewController<ContentTextViewModel> {
    override var acceptsFirstResponder: Bool { true }

    override var shouldDisplayCommonLoading: Bool { true }

    @Dependency(\.sourceEditorLoader) private var sourceEditorLoader

    @Dependency(\.settings) private var settings

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

    /// Keeps the editor's margins and overlays following Settings › Editor. The observation
    /// re-runs on any change to `settings.editor` without saying which value moved, which is
    /// why the bridge takes all five at once and diffs them itself.
    private var displayOptionsObserveToken: ObserveToken?

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let bridge else { return }
        bridge.navigationDelegate = self

        effectiveAppearanceObservation = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.applyCurrentTheme()
            }
        }

        displayOptionsObserveToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            let editorSettings = settings.editor
            bridge.applyDisplayOptions(
                showsLineNumbers: editorSettings.showsLineNumbers,
                showsFoldingRibbon: editorSettings.showsFoldingRibbon,
                showsStickyHeaders: editorSettings.showsStickyHeaders,
                showsMinimap: editorSettings.showsMinimap,
                showsScopeGuides: editorSettings.showsScopeGuides
            )
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

        Driver.combineLatest(output.renderedInterface, viewModel.$runtimeObject.asDriver())
            .driveOnNext { [weak self] renderedInterface, runtimeObject in
                guard let self else { return }
                displayedAttributedString = renderedInterface.attributedString

                // The parse the editor makes of this text cannot tell what an identifier is;
                // these runs can, so they are handed over to correct it.
                let (semanticRanges, nodeTypeNames) = Self.semanticNodeTypes(of: renderedInterface.semanticString)
                bridge?.setSource(
                    renderedInterface.attributedString.string,
                    languageIdentifier: Self.languageIdentifier(for: runtimeObject.kind),
                    semanticRanges: semanticRanges,
                    semanticNodeTypeNames: nodeTypeNames
                )
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

        // The gutter has no theme key of its own, so its font is passed alongside. Same font
        // as the text, which is what makes a number line up with the row it labels.
        let lineNumberFont = currentTheme?.font(for: .standard) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        bridge.applyTheme(name: baseThemeName, dictionary: dictionary, fontSizeModifier: 0, lineNumberFont: lineNumberFont)

        // The theme covers the text area; these cover everything around it — the area past
        // the end of the document, and the container behind the editor.
        if let backgroundColor = currentTheme?.backgroundColor {
            bridge.applyBackgroundColor(backgroundColor)
            (contentView as? UXView)?.backgroundColor = backgroundColor
        }
    }

    /// Walks the generator's semantic runs into the two parallel arrays the bridge takes.
    ///
    /// The node type names are the same strings as the theme's syntax keys, so
    /// `SourceEditorThemeConversion`'s table serves both directions — it maps a `SemanticType`
    /// to a key for coloring, and to a node type name here.
    ///
    /// Offsets are accumulated in UTF-16 because that is what the editor, `NSRange` and
    /// `NSAttributedString` all index by; counting `Character`s would drift on anything
    /// outside the basic plane.
    private static func semanticNodeTypes(of semanticString: SemanticString) -> (ranges: [NSValue], nodeTypeNames: [String]) {
        var ranges: [NSValue] = []
        var nodeTypeNames: [String] = []
        var location = 0

        semanticString.enumerate { text, semanticType in
            let length = text.utf16.count
            defer { location += length }
            guard length > 0 else { return }
            ranges.append(NSValue(range: NSRange(location: location, length: length)))
            nodeTypeNames.append(SourceEditorThemeConversion.syntaxColorKey(for: semanticType))
        }

        return (ranges, nodeTypeNames)
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

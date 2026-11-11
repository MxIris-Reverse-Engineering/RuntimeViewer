import AppKit
import RuntimeViewerApplication
import RuntimeViewerCrossReferences
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import RuntimeViewerSourceEditorBridge
import RuntimeViewerUI
import Semantic

/// Content pane backed by SourceEditor, the reconstruction of Xcode's editor that official builds
/// carry, instead of `NSTextView`.
///
/// It binds the same `ContentTextViewModel` as `ContentTextViewController`, so the two are
/// interchangeable and the fallback costs nothing beyond choosing a different class.
///
/// The editor parses the plain text itself and so cannot tell what an identifier is; the
/// generator's semantic runs are passed alongside the text to correct that parse, through the
/// framework's own node-type adjuster. Coloring therefore comes out semantic, and so do token
/// ranges — which is what ⌘-click reads.
final class ContentSourceEditorViewController: BaseViewController<ContentTextViewModel> {
    override var acceptsFirstResponder: Bool { true }

    override var shouldDisplayCommonLoading: Bool { true }

    @Dependency(\.sourceEditorBridgeProvider) private var sourceEditorBridgeProvider

    @Dependency(\.settings) private var settings

    private lazy var bridge: SourceEditorBridging? = sourceEditorBridgeProvider.makeBridge()

    /// What takes the keyboard focus when the editor pane showing this does (`EditorPaneContent`).
    var focusableView: NSView? { bridge?.editorView }

    /// The string currently handed to the editor. ⌘-click reports a UTF-16 range into this
    /// very string, so the generator's `.link` attribute can be read straight off it.
    private var displayedAttributedString: NSAttributedString?

    private let jumpToDefinitionRelay = PublishRelay<RuntimeObject>()

    private let openInNewTabRelay = PublishRelay<RuntimeObject>()

    private let openInNextEditorPaneRelay = PublishRelay<RuntimeObject>()

    /// Find Call Hierarchy and the other cross-reference commands chosen in the right-click menu.
    /// The insertion point is not followed here: the bridge reports no selection changes.
    private let crossReferenceRequestedRelay = PublishRelay<FindCrossReferenceRequest>()

    /// The commands every list offers on a runtime object, chosen on a type link.
    private let runtimeObjectActionRequestedRelay = PublishRelay<RuntimeObjectActionRequest>()

    private let generatedInterfaceToggledRelay = PublishRelay<SelectionRoute.Destination>()

    /// `viewDidChangeEffectiveAppearance` is an `NSView` callback, not an `NSViewController`
    /// one, so the appearance switch has to be observed rather than overridden.
    private var effectiveAppearanceObservation: NSKeyValueObservation?

    /// Held because the theme has to be re-applied on an appearance change too, and that
    /// notification carries no theme with it.
    private var currentTheme: ThemeProfile?

    /// Keeps the editor's margins and overlays following Settings › Editor. The observation
    /// re-runs on any change to `settings.editor` without saying which value moved, which is
    /// why the bridge takes them all at once and diffs them itself.
    private var displayOptionsObserveToken: ObserveToken?

    /// The language the current source was handed over as. The minimap's hover icons colour
    /// type-level landmarks by it, the way the sidebar colours Objective-C and Swift apart.
    private var displayedLanguageIdentifier: String?

    /// What the editor shows.
    private var displayedRenderedInterface: ContentTextViewModel.RenderedInterface?

    /// The text last handed to the editor. A source shown again unchanged — a theme or font change
    /// renders the same text anew — gets back the macro expansions that were open, which the
    /// editor drops with every source it is given.
    private var lastShownSource: String?

    /// Set while the view model's first render is still to come and a Find navigator hit is to
    /// be revealed after it: that render must not put the reader back where they last left the
    /// interface, or the restore, which waits for a layout, could scroll the hit away again.
    private var awaitsHighlightedFirstRender = false

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let bridge else { return }
        bridge.navigationDelegate = self
        bridge.minimapLandmarkIconProvider = self

        effectiveAppearanceObservation = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.applyCurrentTheme()
            }
        }

        displayOptionsObserveToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            // Comment tags are not among them: they are a part of the source, which the view
            // model fetches again, with or without the comment structure, when they are turned
            // on or off.
            bridge.applyDisplayOptions(from: settings.editor)
        }

        containerView.hierarchy {
            bridge.editorView
        }

        // Top goes to the superview, not the safe area, so text scrolls under the toolbar the
        // way it does in the `NSTextView` pane. What that pane got for free — AppKit deriving
        // the scroll view's content insets from the safe area — has to be handed over
        // explicitly here, in `viewDidLayout`, because the scroll view is buried inside
        // `SourceEditorView` and it turns that adjustment off.
        bridge.editorView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        guard let bridge else { return }
        // **`view`, not `bridge.editorView`.** The editor view reads a zero safe area here —
        // AppKit resolves it against the controller's view, and nothing re-derives it for a
        // descendant that happens to extend past it. Asking the editor view directly returns
        // the right answer only when it is a direct subview of the window's content view,
        // which is true of a test harness and not of this pane.
        //
        // Re-read every layout rather than stored: it moves with the toolbar, full screen and
        // window chrome, none of which reaches the content pane as a notification.
        bridge.applyTopContentInset(view.safeAreaInsets.top)
    }


    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: jumpToDefinitionRelay.asSignal(),
            runtimeObjectOpenedInNewTab: openInNewTabRelay.asSignal(),
            runtimeObjectOpenedInNextEditorPane: openInNextEditorPaneRelay.asSignal(),
            crossReferenceRequested: crossReferenceRequestedRelay.asSignal(),
            generatedInterfaceToggled: generatedInterfaceToggledRelay.asSignal(),
            runtimeObjectActionRequested: runtimeObjectActionRequestedRelay.asSignal()
        )
        let output = viewModel.transform(input)
        awaitsHighlightedFirstRender = output.highlightsFirstRender

        let interfaceLanguage = viewModel.interfaceLanguage
        Driver.combineLatest(output.renderedInterface, viewModel.$runtimeObject.asDriver())
            .driveOnNext { [weak self] renderedInterface, runtimeObject in
                guard let self else { return }
                displayedAttributedString = renderedInterface.attributedString
                displayedRenderedInterface = renderedInterface
                displayedLanguageIdentifier = Self.languageIdentifier(for: runtimeObject.kind, interfaceLanguage: interfaceLanguage)
                showDisplayedSource()
            }
            .disposed(by: rx.disposeBag)

        output.theme.driveOnNext { [weak self] theme in
            guard let self else { return }
            currentTheme = theme
            applyCurrentTheme()
        }
        .disposed(by: rx.disposeBag)

        // Before the reveal of the same hit, which the view model emits next.
        output.findBarQuery.emitOnNextMainActor { [weak self] findBarQuery in
            guard let self else { return }
            bridge?.showFindInterface(
                query: findBarQuery.text,
                pattern: Self.findPattern(for: findBarQuery.matchMode),
                isCaseSensitive: findBarQuery.isCaseSensitive
            )
        }
        .disposed(by: rx.disposeBag)

        output.highlightRange.emitOnNextMainActor { [weak self] range in
            guard let self else { return }
            bridge?.revealCharacterRange(range)
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectNotFound.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            var configuration = HUDView.Configuration.standard()
            configuration.image = SFSymbols(systemName: .questionmark, pointSize: 80, weight: .light).nsuiImage
            view.window?.showHUD(with: configuration)
        }
        .disposed(by: rx.disposeBag)
    }

    /// Hands the editor the source last rendered, with its comment decorations while comment tags
    /// are on — checked here too, since a fetch made before they were turned off can still
    /// arrive with them.
    private func showDisplayedSource() {
        guard let bridge, let renderedInterface = displayedRenderedInterface, let languageIdentifier = displayedLanguageIdentifier else { return }

        // The parse the editor makes of this text cannot tell what an identifier is;
        // these runs can, so they are handed over to correct it.
        let (semanticRanges, nodeTypeNames) = Self.semanticNodeTypes(of: renderedInterface.semanticString)
        let commentDecorations = settings.editor.showsCommentTags
            ? renderedInterface.commentDecorations.flatMap { $0.isEmpty ? nil : SourceEditorCommentDecorations($0) }
            : nil
        let source = renderedInterface.attributedString.string
        let reopenedExpansions = source == lastShownSource
            ? renderedInterface.macroExpansions.filter { bridge.isInlineExpansionShown(identifier: Self.inlineExpansionIdentifier(for: $0)) }
            : []
        bridge.setSource(
            source,
            languageIdentifier: languageIdentifier,
            semanticRanges: semanticRanges,
            semanticNodeTypeNames: nodeTypeNames,
            commentDecorations: commentDecorations,
            restoresScrollPosition: !awaitsHighlightedFirstRender
        )
        lastShownSource = source
        awaitsHighlightedFirstRender = false
        for expansion in reopenedExpansions {
            showInlineExpansion(expansion, with: bridge)
        }
    }

    // MARK: - Macro Expansions

    /// Expand Macro on an attached macro's attribute, Hide Macro Expansion once it is expanded —
    /// what Xcode's editor offers on a macro. `nil` for a token outside every attribute.
    private func macroExpansionMenuItem(forTokenIn characterRange: NSRange) -> NSMenuItem? {
        guard let bridge, let expansion = displayedRenderedInterface?.macroExpansions.first(where: {
            NSLocationInRange(characterRange.location, $0.attributeCharacterRange)
        }) else { return nil }
        let isShown = bridge.isInlineExpansionShown(identifier: Self.inlineExpansionIdentifier(for: expansion))
        return NSMenuItem(title: isShown ? "Hide Macro Expansion" : "Expand Macro", action: #selector(macroExpansionAction(_:)), keyEquivalent: "").then {
            $0.target = self
            $0.representedObject = expansion
        }
    }

    @objc private func macroExpansionAction(_ sender: NSMenuItem) {
        guard let bridge, let expansion = sender.representedObject as? ContentTextViewModel.MacroExpansion else { return }
        let identifier = Self.inlineExpansionIdentifier(for: expansion)
        if bridge.isInlineExpansionShown(identifier: identifier) {
            bridge.hideInlineExpansion(identifier: identifier)
        } else {
            showInlineExpansion(expansion, with: bridge)
        }
    }

    /// Shows the declarations the macro generated below its attribute's line, coloured the way the
    /// interface is.
    private func showInlineExpansion(_ expansion: ContentTextViewModel.MacroExpansion, with bridge: SourceEditorBridging) {
        let (semanticRanges, nodeTypeNames) = Self.semanticNodeTypes(of: expansion.expansionString)
        bridge.showInlineExpansion(
            expansion.expansionString.string,
            languageIdentifier: "swift",
            semanticRanges: semanticRanges,
            semanticNodeTypeNames: nodeTypeNames,
            title: expansion.macroName.split(separator: ".").last.map(String.init) ?? expansion.macroName,
            identifier: Self.inlineExpansionIdentifier(for: expansion),
            belowLineContaining: expansion.attributeCharacterRange
        )
    }

    /// Names an expansion by its macro and where its attribute is, which stays the same while the
    /// text does.
    private static func inlineExpansionIdentifier(for expansion: ContentTextViewModel.MacroExpansion) -> String {
        "\(expansion.macroName)@\(expansion.attributeCharacterRange.location)"
    }

    /// The find bar's pattern closest to the way the Find navigator's search matched the query.
    /// Close, not equal: the bar bounds words with ICU's `\b`, the engine with its own identifier
    /// boundaries, which count `$` as part of a word (`RuntimeTextPattern.regularExpression(_:boundedAs:)`);
    /// and the bar folds the case of every letter, the engine's literal search of ASCII letters
    /// alone. A hit the navigator found can therefore be missing from the bar's matches, or the
    /// other way round, in names with `$` or letters outside ASCII.
    private static func findPattern(for matchMode: RuntimeInterfaceSearchMatchMode) -> SourceEditorBridgingFindPattern {
        switch matchMode {
        case .containing: .contains
        case .matchingWord: .matchesWord
        case .startingWith: .startsWith
        case .endingWith: .endsWith
        case .regularExpression: .regularExpression
        }
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
        guard let baseTheme = sourceEditorBridgeProvider.builtInThemeDictionary(named: baseThemeName) else { return }

        let dictionary = currentTheme.flatMap {
            SourceEditorThemeConversion.themeDictionary(from: $0, basedOn: baseTheme)
        } ?? baseTheme

        // The gutter has no theme key of its own, so its font is passed alongside. Same font
        // as the text, which is what makes a number line up with the row it labels.
        let lineNumberFont = currentTheme?.font(for: .standard) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        bridge.applyTheme(name: baseThemeName, dictionary: dictionary, fontSizeModifier: 0, lineNumberFont: lineNumberFont)

        bridge.applyCommentTagAppearance(SourceEditorCommentTagAppearance(
            commentColor: currentTheme?.color(for: .comment) ?? .secondaryLabelColor,
            // What the theme dictionary above gives the comment keys, so a raised tag line is
            // measured against the font its text is drawn in.
            commentFont: currentTheme?.font(for: .comment) ?? lineNumberFont,
            typeColor: currentTheme?.color(for: .type(.class, .name)) ?? .labelColor,
            textColor: currentTheme?.color(for: .standard) ?? .labelColor,
            isDark: isDark
        ))

        // The theme covers the text area; these cover everything around it — the area past
        // the end of the document, and the container behind the editor.
        if let backgroundColor = currentTheme?.backgroundColor {
            bridge.applyBackgroundColor(backgroundColor)
            containerView._backgroundColor = backgroundColor
            commonLoadingView.backgroundColor = backgroundColor
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
    private static func semanticNodeTypes(of semanticString: FrozenSemanticString) -> (ranges: [NSValue], nodeTypeNames: [String]) {
        var ranges: [NSValue] = []
        var nodeTypeNames: [String] = []
        var location = 0

        semanticString.enumerateSpans { spanText, semanticType, _ in
            let length = spanText.utf16.count
            defer { location += length }
            guard length > 0 else { return }
            ranges.append(NSValue(range: NSRange(location: location, length: length)))
            nodeTypeNames.append(SourceEditorThemeConversion.syntaxColorKey(for: semanticType))
        }

        return (ranges, nodeTypeNames)
    }

    /// The language the editor highlights an interface as: the language it is asked for in, or the
    /// object's own — an Objective-C object's Generated Interface is Swift.
    private static func languageIdentifier(for kind: RuntimeObjectKind, interfaceLanguage: RuntimeInterfaceLanguage?) -> String {
        if interfaceLanguage == .swift {
            return "swift"
        }
        return switch kind {
        case .swift: "swift"
        case .objc, .c: "objc"
        }
    }
}

// MARK: - Navigation

extension ContentSourceEditorViewController: SourceEditorBridgingNavigationDelegate {
    func sourceEditorBridge(_ bridge: SourceEditorBridging, didCommandClickTokenIn characterRange: NSRange) {
        guard let runtimeObject = runtimeObject(atCharacterIndex: characterRange.location) else { return }

        // Same split as the NSTextView path: ⌘-click jumps in place, ⌘⇧-click and ⌥⌘-click open a
        // tab, ⇧⌥⌘-click opens the next editor pane.
        switch SelectionRoute.Destination(linkClickModifierFlags: NSEvent.modifierFlags) {
        case .focusedTab:
            jumpToDefinitionRelay.accept(runtimeObject)
        case .newTab:
            openInNewTabRelay.accept(runtimeObject)
        case .nextEditorPane:
            openInNextEditorPaneRelay.accept(runtimeObject)
        }
    }

    func sourceEditorBridge(_ bridge: SourceEditorBridging, contextualMenuItemsForTokenIn characterRange: NSRange) -> [NSMenuItem] {
        var menuItems: [NSMenuItem] = []
        let runtimeObject = runtimeObject(atCharacterIndex: characterRange.location)
        if let runtimeObject {
            let jumpToDefinitionMenuItem = RuntimeObjectMenuItem(title: "Jump to Definition", symbolName: .arrowTurnDownRight, runtimeObject: runtimeObject)
            jumpToDefinitionMenuItem.target = self
            jumpToDefinitionMenuItem.action = #selector(jumpToDefinitionAction(_:))

            let openInNewTabMenuItem = RuntimeObjectMenuItem(title: "Open in New Tab", symbolName: .plusSquareOnSquare, runtimeObject: runtimeObject)
            openInNewTabMenuItem.target = self
            openInNewTabMenuItem.action = #selector(openInNewTabAction(_:))

            let openInNextEditorPaneMenuItem = RuntimeObjectMenuItem(title: "Open in Next Editor Pane", symbolName: .insetFilledRighthalfRectangle, runtimeObject: runtimeObject)
            openInNextEditorPaneMenuItem.target = self
            openInNextEditorPaneMenuItem.action = #selector(openInNextEditorPaneAction(_:))

            let copyNameMenuItem = RuntimeObjectMenuItem(.copyName, runtimeObject: runtimeObject)
            copyNameMenuItem.target = self
            copyNameMenuItem.action = #selector(runtimeObjectActionMenuItemAction(_:))

            menuItems = [jumpToDefinitionMenuItem, openInNewTabMenuItem, openInNextEditorPaneMenuItem, copyNameMenuItem]
        }

        // As the NSTextView path: the member the token's line declares, and the type a name links to.
        var requests: [FindCrossReferenceRequest] = []
        if let member = declaredMember(atCharacterIndex: characterRange.location) {
            requests += FindCrossReferenceRequest.requests(for: member)
        }
        if let runtimeObject {
            requests += FindCrossReferenceRequest.requests(for: runtimeObject)
        }
        if !requests.isEmpty, !menuItems.isEmpty {
            menuItems.append(.separator())
        }
        menuItems += requests.map { request in
            NSMenuItem(title: request.title, action: #selector(crossReferenceAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.representedObject = request
            }
        }
        if let generatedInterfaceMenuItem = generatedInterfaceMenuItem() {
            if !menuItems.isEmpty {
                menuItems.append(.separator())
            }
            menuItems.append(generatedInterfaceMenuItem)
        }
        if !menuItems.isEmpty {
            menuItems.append(.separator())
        }
        menuItems.append(.revealInSidebarNavigator())
        // At the top, where Xcode puts Expand Macro.
        if let macroExpansionMenuItem = macroExpansionMenuItem(forTokenIn: characterRange) {
            menuItems.insert(contentsOf: [macroExpansionMenuItem, .separator()], at: 0)
        }
        return menuItems
    }

    /// Generated Interface for the object on screen, checked while it is the form shown; `nil` for
    /// an object that has none.
    private func generatedInterfaceMenuItem() -> NSMenuItem? {
        guard let viewModel, viewModel.offersGeneratedInterface else { return nil }
        return NSMenuItem(title: "Generated Interface", action: #selector(generatedInterfaceAction(_:)), keyEquivalent: "").then {
            $0.target = self
            $0.state = viewModel.showsGeneratedInterface ? .on : .off
        }
    }

    @objc private func generatedInterfaceAction(_ sender: NSMenuItem) {
        generatedInterfaceToggledRelay.accept(SelectionRoute.Destination(listClickModifierFlags: NSEvent.modifierFlags))
    }

    /// The member the line holding `characterIndex` declares, if it declares one with code.
    private func declaredMember(atCharacterIndex characterIndex: Int) -> RuntimeMemberReference? {
        guard let displayedAttributedString,
              characterIndex < displayedAttributedString.length
        else { return nil }
        return displayedAttributedString.attribute(.runtimeViewerDeclaredMember, at: characterIndex, effectiveRange: nil) as? RuntimeMemberReference
    }

    @objc private func crossReferenceAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? FindCrossReferenceRequest else { return }
        crossReferenceRequestedRelay.accept(request)
    }

    @objc private func runtimeObjectActionMenuItemAction(_ sender: RuntimeObjectMenuItem) {
        guard let action = sender.runtimeObjectAction else { return }
        runtimeObjectActionRequestedRelay.accept(RuntimeObjectActionRequest(action: action, runtimeObject: sender.runtimeObject))
    }

    /// The jump target the generator recorded for the token starting at `characterIndex`, if
    /// that token is one.
    private func runtimeObject(atCharacterIndex characterIndex: Int) -> RuntimeObject? {
        guard let displayedAttributedString,
              characterIndex < displayedAttributedString.length
        else { return nil }
        return displayedAttributedString.attributes(at: characterIndex, effectiveRange: nil)[.link] as? RuntimeObject
    }

    @objc private func jumpToDefinitionAction(_ sender: RuntimeObjectMenuItem) {
        jumpToDefinitionRelay.accept(sender.runtimeObject)
    }

    @objc private func openInNewTabAction(_ sender: RuntimeObjectMenuItem) {
        openInNewTabRelay.accept(sender.runtimeObject)
    }

    @objc private func openInNextEditorPaneAction(_ sender: RuntimeObjectMenuItem) {
        openInNextEditorPaneRelay.accept(sender.runtimeObject)
    }
}

// MARK: - Minimap Landmark Icons

extension ContentSourceEditorViewController: SourceEditorBridgingMinimapLandmarkIconProvider {
    func sourceEditorBridge(
        _ bridge: SourceEditorBridging,
        minimapIconForLandmarkOfKind kind: SourceEditorBridgingLandmarkKind,
        pointSize: CGFloat
    ) -> NSImage? {
        SourceEditorLandmarkIcon.image(for: kind, isSwift: displayedLanguageIdentifier == "swift", pointSize: pointSize)
    }
}

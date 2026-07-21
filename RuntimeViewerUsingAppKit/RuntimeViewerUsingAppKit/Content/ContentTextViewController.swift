import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class ContentTextViewController: UXKitViewController<ContentTextViewModel>, NSTextViewDelegate {
    override var acceptsFirstResponder: Bool { true }

    override var shouldDisplayCommonLoading: Bool { true }

    private let (scrollView, textView): (NSScrollView, ContentTextView) = {
        let scrollView = NSScrollView()
        let textView = ContentTextView(usingTextLayoutManager: true)

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.contentView.drawsBackground = true
        scrollView.documentView = textView

        textView.isRichText = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        
        return (scrollView, textView)
    }()

    private lazy var lineNumberRulerView = ContentLineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)

    private let eventMonitor = EventMonitor()

    private let jumpToDefinitionRelay = PublishRelay<RuntimeObject>()

    private let openInNewTabRelay = PublishRelay<RuntimeObject>()

    private var isPressedCommand: Bool = false

    private var isPressedShift: Bool = false
    
    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        scrollView.do {
            $0.drawsBackground = true
            $0.hasVerticalRuler = true
            $0.verticalRulerView = lineNumberRulerView
            $0.rulersVisible = true
        }

        textView.do {
            $0.isSelectable = true
            $0.isEditable = false
            $0.usesFindBar = true
            $0.textContainerInset = .init(width: 5.0, height: 5.0)
            $0.linkTextAttributes = [:]
            $0.delegate = self
        }

        lineNumberRulerView.clientView = textView
    }


    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let linkClicked = textView.rx.methodInvoked(#selector(ContentTextView.clicked(onLink:at:))).map { $0[0] as! RuntimeObject }.asSignalOnErrorJustComplete()
        let input = ContentTextViewModel.Input(
            // ⌘-click jumps in place; ⌘⇧-click opens in a new tab (Safari semantics).
            runtimeObjectClicked: Signal.of(linkClicked.filter { [weak self] _ in self?.isPressedCommand == true && self?.isPressedShift != true }, jumpToDefinitionRelay.asSignal()).merge(),
            runtimeObjectOpenedInNewTab: Signal.of(linkClicked.filter { [weak self] _ in self?.isPressedCommand == true && self?.isPressedShift == true }, openInNewTabRelay.asSignal()).merge()
        )
        let output = viewModel.transform(input)

//        viewModel.delayedLoading.driveOnNextMainActor { [weak self] isLoading in
//            guard let self else { return }
//
//            if isLoading {
//                textView.showSkeleton(using: .default)
//            } else {
//                textView.hideSkeleton()
//            }
//        }
//        .disposed(by: rx.disposeBag)

        output.attributedString.drive(with: self) { target, attributedString in
            target.textView.textStorage?.setAttributedString(attributedString)
            target.lineNumberRulerView.reload()
        }
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self) {
            ($0.contentView as? UXView)?.backgroundColor = $1.backgroundColor
            $0.textView.backgroundColor = $1.backgroundColor
            $0.scrollView.backgroundColor = $1.backgroundColor
            $0.lineNumberRulerView.backgroundColor = $1.backgroundColor
            var selectedAttributes = $0.textView.selectedTextAttributes
            selectedAttributes[.backgroundColor] = $1.selectionBackgroundColor
            $0.textView.selectedTextAttributes = selectedAttributes
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectNotFound.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            var configuration = HUDView.Configuration.standard()
            configuration.image = SFSymbols(systemName: .questionmark, pointSize: 80, weight: .light).nsuiImgae
            view.window?.showHUD(with: configuration)
        }
        .disposed(by: rx.disposeBag)

        eventMonitor.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return event }
            isPressedCommand = event.modifierFlags.contains(.command)
            isPressedShift = event.modifierFlags.contains(.shift)
            if isPressedCommand {
                textView.linkTextAttributes = [
                    .cursor: NSCursor.pointingHand,
                ]
            } else {
                textView.linkTextAttributes = [:]
            }
            return event
        }
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        var newMenuItems: [NSMenuItem] = []
        if let runtimeObject = view.attributedString().attributes(at: charIndex, effectiveRange: nil)[.link] as? RuntimeObject {
            let jumpToDefinitionMenuItem = RuntimeObjectMenuItem(title: "Jump to Definition", symbolName: .arrowTurnDownRight, runtimeObject: runtimeObject)
            jumpToDefinitionMenuItem.target = self
            jumpToDefinitionMenuItem.action = #selector(jumpToDefinitionAction(_:))
            newMenuItems.append(jumpToDefinitionMenuItem)

            let openInNewTabMenuItem = RuntimeObjectMenuItem(title: "Open in New Tab", symbolName: .plusSquareOnSquare, runtimeObject: runtimeObject)
            openInNewTabMenuItem.target = self
            openInNewTabMenuItem.action = #selector(openInNewTabAction(_:))
            newMenuItems.append(openInNewTabMenuItem)
        }
        newMenuItems.append(contentsOf: menu.items.filter { $0.action?.isStandardAction ?? false })
        menu.items = newMenuItems
        return menu
    }

    @objc private func jumpToDefinitionAction(_ sender: RuntimeObjectMenuItem) {
        jumpToDefinitionRelay.accept(sender.runtimeObject)
    }

    @objc private func openInNewTabAction(_ sender: RuntimeObjectMenuItem) {
        openInNewTabRelay.accept(sender.runtimeObject)
    }

    override func lateResponderSelectors() -> [Selector] {
        [
            #selector(performTextFinderAction(_:)),
        ]
    }

    override func performTextFinderAction(_ sender: Any?) {
        textView.performTextFinderAction(sender)
    }
}

extension ContentTextViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performTextFinderAction(_:)):
            return true
        default:
            return true
        }
    }
}

private final class RuntimeObjectMenuItem: NSMenuItem {
    let runtimeObject: RuntimeObject

    init(title: String, symbolName: SFSymbols.SystemSymbolName, runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        super.init(title: title, action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            image = SFSymbols(systemName: symbolName).nsuiImgae
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension Selector {
    fileprivate var isStandardAction: Bool {
        self == #selector(NSText.cut(_:)) || self == #selector(NSText.copy(_:)) || self == #selector(NSText.paste(_:))
    }
}

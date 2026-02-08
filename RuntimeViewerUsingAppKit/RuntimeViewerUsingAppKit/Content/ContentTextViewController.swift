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
        let textView = ContentTextView(usingTextLayoutManager: false)

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

    private let eventMonitor = EventMonitor()

    private let jumpToDefinitionRelay = PublishRelay<RuntimeObject>()

    private var isPressedCommand: Bool = false
    
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
        }

        textView.do {
            $0.isSelectable = true
            $0.isEditable = false
            $0.usesFindBar = true
            $0.textContainerInset = .init(width: 5.0, height: 5.0)
            $0.linkTextAttributes = [:]
            $0.delegate = self
        }
    }


    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: Signal.of(textView.rx.methodInvoked(#selector(ContentTextView.clicked(onLink:at:))).map { $0[0] as! RuntimeObject }.asSignalOnErrorJustComplete().filter { [unowned self] _ in isPressedCommand }, jumpToDefinitionRelay.asSignal()).merge()
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
        }
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self) {
            ($0.contentView as? UXView)?.backgroundColor = $1.backgroundColor
            $0.textView.backgroundColor = $1.backgroundColor
            $0.scrollView.backgroundColor = $1.backgroundColor
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectNotFound.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            var configuration = HUDView.Configuration.standard()
            configuration.image = SFSymbols(systemName: .questionmark, pointSize: 80, weight: .light).nsuiImgae
            view.window?.showHUD(with: configuration)
        }
        .disposed(by: rx.disposeBag)

        rx.viewDidAppear.asDriver()
            .flatMapLatest { output.runtimeObjectName }
            .drive(with: self) { $0.viewModel?.appState.currentSubtitle = $1 }
            .disposed(by: rx.disposeBag)

        eventMonitor.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            isPressedCommand = event.modifierFlags.contains(.command)
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
            let menuItem = JumpToDefinitionMenuItem(runtimeObject: runtimeObject)
            menuItem.target = self
            menuItem.action = #selector(jumpToDefinitionAction(_:))
            newMenuItems.append(menuItem)
        }
        newMenuItems.append(contentsOf: menu.items.filter { $0.action?.isStandardAction ?? false })
        menu.items = newMenuItems
        return menu
    }

    @objc private func jumpToDefinitionAction(_ sender: JumpToDefinitionMenuItem) {
        jumpToDefinitionRelay.accept(sender.runtimeObject)
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

private final class JumpToDefinitionMenuItem: NSMenuItem {
    let runtimeObject: RuntimeObject

    init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        super.init(title: "Jump to Definition", action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            image = SFSymbols(systemName: .arrowTurnDownRight).nsuiImgae
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

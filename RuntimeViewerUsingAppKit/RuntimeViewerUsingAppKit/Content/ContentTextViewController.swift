import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentTextViewController: UXKitViewController<ContentTextViewModel>, NSTextViewDelegate {
    override var acceptsFirstResponder: Bool { true }

    let scrollView = ContentTextView.scrollableTextView()

    var textView: ContentTextView { scrollView.documentView as! ContentTextView }

    override var shouldDisplayCommonLoading: Bool { true }

    let eventMonitor = EventMonitor()

    let jumpToDefinitionRelay = PublishRelay<RuntimeObjectName>()

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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

    var isPressedCommand: Bool = false

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: Signal.of(textView.rx.methodInvoked(#selector(ContentTextView.clicked(onLink:at:))).map { $0[0] as! RuntimeObjectName }.asSignalOnErrorJustComplete().filter { [unowned self] _ in isPressedCommand }, jumpToDefinitionRelay.asSignal()).merge()
        )
        let output = viewModel.transform(input)

        output.attributedString.drive(with: self, onNext: { target, attributedString in
            target.textView.textStorage?.setAttributedString(attributedString)
        })
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self, onNext: {
            $0.textView.backgroundColor = $1.backgroundColor
            $0.scrollView.backgroundColor = $1.backgroundColor
        })
        .disposed(by: rx.disposeBag)
        rx.viewDidAppear.asDriver().flatMapLatest { output.imageNameOfRuntimeObject }.compactMap { $0 }.drive(with: self) { $0.view.window?.title = $1 }.disposed(by: rx.disposeBag)
        rx.viewDidAppear.asDriver().flatMapLatest { output.runtimeObjectName }.drive(with: self) { $0.view.window?.subtitle = $1 }.disposed(by: rx.disposeBag)

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
        if let runtimeObject = view.attributedString().attributes(at: charIndex, effectiveRange: nil)[.link] as? RuntimeObjectName {
            let menuItem = JumpToDefinitionMenuItem(runtimeObject: runtimeObject)
            menuItem.target = self
            menuItem.action = #selector(jumpToDefinitionAction(_:))
            newMenuItems.append(menuItem)
        }
        newMenuItems.append(contentsOf: menu.items.filter { $0.action?.isStandardAction ?? false })
        menu.items = newMenuItems
        return menu
    }

    @objc func jumpToDefinitionAction(_ sender: JumpToDefinitionMenuItem) {
        jumpToDefinitionRelay.accept(sender.runtimeObject)
    }
}

class JumpToDefinitionMenuItem: NSMenuItem {
    let runtimeObject: RuntimeObjectName

    init(runtimeObject: RuntimeObjectName) {
        self.runtimeObject = runtimeObject
        super.init(title: "Jump to Definition", action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
//            image = 
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension Selector {
    var isStandardAction: Bool {
        self == #selector(NSText.cut(_:)) || self == #selector(NSText.copy(_:)) || self == #selector(NSText.paste(_:))
    }
}

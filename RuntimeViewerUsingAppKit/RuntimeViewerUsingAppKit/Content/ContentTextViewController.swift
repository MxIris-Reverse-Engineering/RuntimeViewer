//
//  ContentTextViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/7.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class ContentTextView: NSTextView {
    override func clicked(onLink link: Any, at charIndex: Int) {}
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

}

class ContentTextViewController: UXKitViewController<ContentTextViewModel>, NSTextViewDelegate {
    override var acceptsFirstResponder: Bool { true }

    let scrollView = ContentTextView.scrollableTextView()

    var textView: ContentTextView { scrollView.documentView as! ContentTextView }

//    lazy var lineNumberGutter = LineNumberGutter(withTextView: textView, foregroundColor: .secondaryLabelColor, backgroundColor: .clear)

    let eventMonitor = EventMonitor()

    let jumpToDefinitionRelay = PublishRelay<RuntimeObjectType>()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
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
            runtimeObjectClicked: Signal.of(textView.rx.methodInvoked(#selector(ContentTextView.clicked(onLink:at:))).map { $0[0] as! RuntimeObjectType }.asSignalOnErrorJustComplete().filter { [unowned self] _ in isPressedCommand }, jumpToDefinitionRelay.asSignal()).merge()
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
        if let runtimeObjectType = view.attributedString().attributes(at: charIndex, effectiveRange: nil)[.link] as? RuntimeObjectType {
            let menuItem = JumpToDefinitionMenuItem(runtimeObjectType: runtimeObjectType)
            menuItem.target = self
            menuItem.action = #selector(jumpToDefinitionAction(_:))
            newMenuItems.append(menuItem)
        }
        newMenuItems.append(contentsOf: menu.items.filter { $0.action?.isStandardAction ?? false })
        menu.items = newMenuItems
        return menu
    }
    
    
    @objc func jumpToDefinitionAction(_ sender: JumpToDefinitionMenuItem) {
        jumpToDefinitionRelay.accept(sender.runtimeObjectType)
    }
}

class JumpToDefinitionMenuItem: NSMenuItem {
    let runtimeObjectType: RuntimeObjectType
    
    init(runtimeObjectType: RuntimeObjectType) {
        self.runtimeObjectType = runtimeObjectType
        super.init(title: "Jump to Definition", action: nil, keyEquivalent: "")
    }
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension Selector {
    var isStandardAction: Bool {
        self == #selector(NSText.cut(_:)) || self == #selector(NSText.copy(_:)) || self == #selector(NSText.paste(_:))
    }
}

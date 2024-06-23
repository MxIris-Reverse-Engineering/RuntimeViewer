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
    override func clicked(onLink link: Any, at charIndex: Int) {
        print(link, charIndex)
    }
}

class ContentTextViewController: ViewController<ContentTextViewModel> {
    override var acceptsFirstResponder: Bool { true }

    let scrollView = ContentTextView.scrollableTextView()

    var textView: ContentTextView { scrollView.documentView as! ContentTextView }

//    lazy var lineNumberGutter = LineNumberGutter(withTextView: textView, foregroundColor: .secondaryLabelColor, backgroundColor: .clear)

    let eventMonitor = EventMonitor()

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
        }
    }

    var isPressedCommand: Bool = false

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input(
            runtimeObjectClicked: textView.rx.methodInvoked(#selector(ContentTextView.clicked(onLink:at:))).map { $0[0] as! RuntimeObjectType }.asSignalOnErrorJustComplete().filter { [unowned self] _ in isPressedCommand }
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
}

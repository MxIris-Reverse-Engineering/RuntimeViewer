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

class ContentTextView: NSTextView {}

class ContentTextViewController: ViewController<ContentTextViewModel> {
    override var acceptsFirstResponder: Bool { true }

    let scrollView = ContentTextView.scrollableTextView()

    var textView: ContentTextView { scrollView.documentView as! ContentTextView }

    lazy var lineNumberGutter = LineNumberGutter(withTextView: textView, foregroundColor: .secondaryLabelColor, backgroundColor: .clear)

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        scrollView.do {
            $0.rulersVisible = true
            $0.hasVerticalRuler = true
            $0.verticalRulerView = lineNumberGutter
        }

        textView.do {
            $0.isSelectable = true
            $0.isEditable = false
            $0.usesFindBar = true
            $0.textContainerInset = .init(width: 5.0, height: 0)
        }
    }

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)

        let input = ContentTextViewModel.Input()
        let output = viewModel.transform(input)

        output.attributedString.drive(with: self, onNext: { target, attributedString in
//            target.textView.setAttributedString(attributedString)

//            target.textView.string = attributedString.string
            target.textView.textStorage?.setAttributedString(attributedString)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                target.textView.scroll(.zero)
//            }
        })
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self, onNext: {
            $0.textView.backgroundColor = $1.backgroundColor
            $0.lineNumberGutter.backgroundColor = $1.backgroundColor
//            $0.textView.selectionBackgroundColor = $1.selectionBackgroundColor
        })
        .disposed(by: rx.disposeBag)
    }
}

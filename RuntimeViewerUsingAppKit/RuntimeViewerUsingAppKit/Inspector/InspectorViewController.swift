//
//  InspectorViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class InspectorViewController: ViewController<InspectorViewModel> {
    let visualEffectView = NSVisualEffectView()

    let generationOptionsLabel = Label("Generation Options")

    let stripProtocolConformanceCheckbox = CheckboxButton(title: "Strip Protocol Conformance")

    let stripOverridesCheckbox = CheckboxButton(title: "Strip Overrides")

    let stripDuplicatesCheckbox = CheckboxButton(title: "Strip Duplicates")

    let stripSynthesizedCheckbox = CheckboxButton(title: "Strip Synthesized")

    let stripCtorMethodCheckbox = CheckboxButton(title: "Strip Ctor Method")

    let stripDtorMethodCheckbox = CheckboxButton(title: "Strip Dtor Method")

    let addSymbolImageCommentsCheckbox = CheckboxButton(title: "Add Symbol Image Comments")

    let addIvarOffsetCommentsCheckbox = CheckboxButton(title: "Add Ivar Offset Comments")

    lazy var generationOptionsView = VStackView(alignment: .left, spacing: 10) {
        generationOptionsLabel
        stripProtocolConformanceCheckbox
        stripOverridesCheckbox
        stripDuplicatesCheckbox
        stripSynthesizedCheckbox
        stripCtorMethodCheckbox
        stripDtorMethodCheckbox
        addSymbolImageCommentsCheckbox
        addIvarOffsetCommentsCheckbox
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            visualEffectView.hierarchy {
                generationOptionsView
            }
        }

        visualEffectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        generationOptionsView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.left.equalToSuperview().inset(15)
            make.right.equalToSuperview()
            make.height.equalTo(250)
        }
    }

    override func setupBindings(for viewModel: InspectorViewModel) {
        super.setupBindings(for: viewModel)

        let input = InspectorViewModel.Input(
            stripProtocolConformanceChecked: stripProtocolConformanceCheckbox.rx.state.asSignal().map { $0 == .on },
            stripOverridesChecked: stripOverridesCheckbox.rx.state.asSignal().map { $0 == .on },
            stripDuplicatesChecked: stripDuplicatesCheckbox.rx.state.asSignal().map { $0 == .on },
            stripSynthesizedChecked: stripSynthesizedCheckbox.rx.state.asSignal().map { $0 == .on },
            stripCtorMethodChecked: stripCtorMethodCheckbox.rx.state.asSignal().map { $0 == .on },
            stripDtorMethodChecked: stripDtorMethodCheckbox.rx.state.asSignal().map { $0 == .on },
            addSymbolImageCommentsChecked: addSymbolImageCommentsCheckbox.rx.state.asSignal().map { $0 == .on },
            addIvarOffsetCommentsChecked: addIvarOffsetCommentsCheckbox.rx.state.asSignal().map { $0 == .on }
        )
        let output = viewModel.transform(input)

        output.stripProtocolConformanceChecked.drive(stripProtocolConformanceCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripOverridesChecked.drive(stripOverridesCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripDuplicatesChecked.drive(stripDuplicatesCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripSynthesizedChecked.drive(stripSynthesizedCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripCtorMethodChecked.drive(stripCtorMethodCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripDtorMethodChecked.drive(stripDtorMethodCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.addSymbolImageCommentsChecked.drive(addSymbolImageCommentsCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
    }
}

extension CheckboxButton: @unchecked Sendable {
    convenience init(title: String, titleFont: NSFont? = nil, titleColor: NSColor? = nil, titleSpacing: CGFloat = 5.0) {
        self.init()
        self.attributedTitle = NSAttributedString {
            AText(title)
                .font(titleFont ?? .systemFont(ofSize: 13))
                .foregroundColor(titleColor ?? .labelColor)
                .paragraphStyle(NSMutableParagraphStyle().then {
                    $0.firstLineHeadIndent = titleSpacing
                    $0.lineBreakMode = .byClipping
                })
        }
    }
}

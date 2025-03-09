//
//  GenerationOptionsViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/29.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class GenerationOptionsViewController: AppKitViewController<GenerationOptionsViewModel<MainRoute>> {
    let generationOptionsLabel = Label("Generation Options")

    let stripProtocolConformanceCheckbox = CheckboxButton(title: "Strip Protocol Conformance")

    let stripOverridesCheckbox = CheckboxButton(title: "Strip Overrides")

    let stripDuplicatesCheckbox = CheckboxButton(title: "Strip Duplicates")

    let stripSynthesizedCheckbox = CheckboxButton(title: "Strip Synthesized")

    let stripCtorMethodCheckbox = CheckboxButton(title: "Strip Ctor Method")

    let stripDtorMethodCheckbox = CheckboxButton(title: "Strip Dtor Method")

    let addSymbolImageCommentsCheckbox = CheckboxButton(title: "Add Symbol Image Comments")

    let addIvarOffsetCommentsCheckbox = CheckboxButton(title: "Add Ivar Offset Comments")

    let expandIvarRecordTypeMembersCheckbox = CheckboxButton(title: "Expand Ivar Record Type Members")
    
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
        expandIvarRecordTypeMembersCheckbox
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            generationOptionsView
        }

        generationOptionsView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(15)
        }

        preferredContentSize = generationOptionsView.fittingSize.inset(15)
    }

    override func setupBindings(for viewModel: GenerationOptionsViewModel<MainRoute>) {
        super.setupBindings(for: viewModel)

        let input = GenerationOptionsViewModel<MainRoute>.Input(
            stripProtocolConformanceChecked: stripProtocolConformanceCheckbox.rx.state.asSignal().map { $0 == .on },
            stripOverridesChecked: stripOverridesCheckbox.rx.state.asSignal().map { $0 == .on },
            stripDuplicatesChecked: stripDuplicatesCheckbox.rx.state.asSignal().map { $0 == .on },
            stripSynthesizedChecked: stripSynthesizedCheckbox.rx.state.asSignal().map { $0 == .on },
            stripCtorMethodChecked: stripCtorMethodCheckbox.rx.state.asSignal().map { $0 == .on },
            stripDtorMethodChecked: stripDtorMethodCheckbox.rx.state.asSignal().map { $0 == .on },
            addSymbolImageCommentsChecked: addSymbolImageCommentsCheckbox.rx.state.asSignal().map { $0 == .on },
            addIvarOffsetCommentsChecked: addIvarOffsetCommentsCheckbox.rx.state.asSignal().map { $0 == .on },
            expandIvarRecordTypeMembersChecked: expandIvarRecordTypeMembersCheckbox.rx.state.asSignal().map { $0 == .on }
        )
        let output = viewModel.transform(input)

        output.stripProtocolConformanceChecked.drive(stripProtocolConformanceCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripOverridesChecked.drive(stripOverridesCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripDuplicatesChecked.drive(stripDuplicatesCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripSynthesizedChecked.drive(stripSynthesizedCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripCtorMethodChecked.drive(stripCtorMethodCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.stripDtorMethodChecked.drive(stripDtorMethodCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.addSymbolImageCommentsChecked.drive(addSymbolImageCommentsCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.addIvarOffsetCommentsChecked.drive(addIvarOffsetCommentsCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
        output.expandIvarRecordTypeMembersChecked.drive(expandIvarRecordTypeMembersCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
    }
}

extension CGSize {
    func inset(_ value: CGFloat) -> CGSize {
        return .init(width: width + value * 2, height: height + value * 2)
    }
}

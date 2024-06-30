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

class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    public struct Input {
        public let stripProtocolConformanceChecked: Signal<Bool>
        public let stripOverridesChecked: Signal<Bool>
        public let stripDuplicatesChecked: Signal<Bool>
        public let stripSynthesizedChecked: Signal<Bool>
        public let stripCtorMethodChecked: Signal<Bool>
        public let stripDtorMethodChecked: Signal<Bool>
        public let addSymbolImageCommentsChecked: Signal<Bool>
        public let addIvarOffsetCommentsChecked: Signal<Bool>
        public init(stripProtocolConformanceChecked: Signal<Bool>, stripOverridesChecked: Signal<Bool>, stripDuplicatesChecked: Signal<Bool>, stripSynthesizedChecked: Signal<Bool>, stripCtorMethodChecked: Signal<Bool>, stripDtorMethodChecked: Signal<Bool>, addSymbolImageCommentsChecked: Signal<Bool>, addIvarOffsetCommentsChecked: Signal<Bool>) {
            self.stripProtocolConformanceChecked = stripProtocolConformanceChecked
            self.stripOverridesChecked = stripOverridesChecked
            self.stripDuplicatesChecked = stripDuplicatesChecked
            self.stripSynthesizedChecked = stripSynthesizedChecked
            self.stripCtorMethodChecked = stripCtorMethodChecked
            self.stripDtorMethodChecked = stripDtorMethodChecked
            self.addSymbolImageCommentsChecked = addSymbolImageCommentsChecked
            self.addIvarOffsetCommentsChecked = addIvarOffsetCommentsChecked
        }
    }

    public struct Output {
        public let stripProtocolConformanceChecked: Driver<Bool>
        public let stripOverridesChecked: Driver<Bool>
        public let stripDuplicatesChecked: Driver<Bool>
        public let stripSynthesizedChecked: Driver<Bool>
        public let stripCtorMethodChecked: Driver<Bool>
        public let stripDtorMethodChecked: Driver<Bool>
        public let addSymbolImageCommentsChecked: Driver<Bool>
        public let addIvarOffsetCommentsChecked: Driver<Bool>
    }

    public func transform(_ input: Input) -> Output {
        input.stripProtocolConformanceChecked.emitOnNext { AppDefaults[\.options].stripProtocolConformance = $0 }.disposed(by: rx.disposeBag)
        input.stripOverridesChecked.emitOnNext { AppDefaults[\.options].stripOverrides = $0 }.disposed(by: rx.disposeBag)
        input.stripDuplicatesChecked.emitOnNext { AppDefaults[\.options].stripDuplicates = $0 }.disposed(by: rx.disposeBag)
        input.stripSynthesizedChecked.emitOnNext { AppDefaults[\.options].stripSynthesized = $0 }.disposed(by: rx.disposeBag)
        input.stripCtorMethodChecked.emitOnNext { AppDefaults[\.options].stripCtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.stripDtorMethodChecked.emitOnNext { AppDefaults[\.options].stripDtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.addSymbolImageCommentsChecked.emitOnNext { AppDefaults[\.options].addSymbolImageComments = $0 }.disposed(by: rx.disposeBag)
        input.addIvarOffsetCommentsChecked.emitOnNext { AppDefaults[\.options].addIvarOffsetComments = $0 }.disposed(by: rx.disposeBag)

        return Output(
            stripProtocolConformanceChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripProtocolConformance),
            stripOverridesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripOverrides),
            stripDuplicatesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDuplicates),
            stripSynthesizedChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripSynthesized),
            stripCtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripCtorMethod),
            stripDtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDtorMethod),
            addSymbolImageCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addSymbolImageComments),
            addIvarOffsetCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addIvarOffsetComments)
        )
    }
}

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
        output.addIvarOffsetCommentsChecked.drive(addIvarOffsetCommentsCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
    }
}

extension CGSize {
    func inset(_ value: CGFloat) -> CGSize {
        return .init(width: width + value * 2, height: height + value * 2)
    }
}

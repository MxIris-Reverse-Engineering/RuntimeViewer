import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class GenerationOptionsViewController: AppKitViewController<GenerationOptionsViewModel<MainRoute>> {
    private struct OptionItem {
        let title: String
        let keyPath: OptionKeyPath
    }

    private struct Section {
        let title: String?
        let items: [OptionItem]
    }

    private lazy var sections: [Section] = [
        Section(title: "ObjC", items: [
            OptionItem(title: "Strip Protocol Conformance", keyPath: \.objcHeaderOptions.stripProtocolConformance),
            OptionItem(title: "Strip Overrides", keyPath: \.objcHeaderOptions.stripOverrides),
//            OptionItem(title: "Strip Duplicates", keyPath: \.objcHeaderOptions.stripDuplicates),
            OptionItem(title: "Strip Synthesized Ivars", keyPath: \.objcHeaderOptions.stripSynthesizedIvars),
            OptionItem(title: "Strip Synthesized Methods", keyPath: \.objcHeaderOptions.stripSynthesizedMethods),
            OptionItem(title: "Strip Ctor Method", keyPath: \.objcHeaderOptions.stripCtorMethod),
            OptionItem(title: "Strip Dtor Method", keyPath: \.objcHeaderOptions.stripDtorMethod),
//            OptionItem(title: "Add Symbol Image Comments", keyPath: \.objcHeaderOptions.addSymbolImageComments),
            OptionItem(title: "Add Ivar Offset Comments", keyPath: \.objcHeaderOptions.addIvarOffsetComments),
//            OptionItem(title: "Expand Ivar Record Type Members", keyPath: \.objcHeaderOptions.expandIvarRecordTypeMembers),
            OptionItem(title: "Add Property Attributes Comments", keyPath: \.objcHeaderOptions.addPropertyAttributesComments),
        ]),
        Section(title: "Swift", items: [
            OptionItem(title: "Print Stripped Symbol Description", keyPath: \.swiftInterfaceOptions.printStrippedSymbolicItem),
            OptionItem(title: "Print Offset Comments", keyPath: \.swiftInterfaceOptions.emitOffsetComments),
            OptionItem(title: "Print Type Layout", keyPath: \.swiftInterfaceOptions.printTypeLayout),
            OptionItem(title: "Print Enum Layout", keyPath: \.swiftInterfaceOptions.printEnumLayout),
        ]),
    ]

    private let generationOptionsLabel = Label("Generation Options")

    private lazy var stackView = VStackView(alignment: .left, spacing: 10) {
        generationOptionsLabel
    }

    private var checkboxMap: [OptionKeyPath: CheckboxButton] = [:]

    private let updateRelay = PublishRelay<(OptionKeyPath, Bool)>()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            stackView
        }

        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(15)
        }

        for section in sections {
            if let title = section.title {
                let label = Label(title).then {
                    $0.textColor = .secondaryLabelColor
                }
                stackView.addArrangedSubview(label)
            }

            for item in section.items {
                let checkbox = CheckboxButton(title: item.title)
                stackView.addArrangedSubview(checkbox)

                checkboxMap[item.keyPath] = checkbox
            }
        }

        preferredContentSize = stackView.fittingSize.inset(15)
    }

    override func setupBindings(for viewModel: GenerationOptionsViewModel<MainRoute>) {
        super.setupBindings(for: viewModel)

        for (keyPath, checkbox) in checkboxMap {
            checkbox.rx.state.asSignal()
                .map { $0 == .on }
                .map { (keyPath, $0) }
                .emit(to: updateRelay)
                .disposed(by: rx.disposeBag)
        }

        let input = GenerationOptionsViewModel<MainRoute>.Input(
            updateOption: updateRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.options
            .drive(onNext: { [weak self] options in
                guard let self = self else { return }

                for (keyPath, checkbox) in self.checkboxMap {
                    let isChecked = options[keyPath: keyPath]
                    checkbox.state = isChecked ? .on : .off
                }
            })
            .disposed(by: rx.disposeBag)
    }
}

extension CGSize {
    fileprivate func inset(_ value: CGFloat) -> CGSize {
        return .init(width: width + value * 2, height: height + value * 2)
    }
}

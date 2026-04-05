import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCore

final class GenerationOptionsViewController: AppKitViewController<GenerationOptionsViewModel<MainRoute>> {
    private enum OptionItem {
        case checkbox(title: String, keyPath: OptionKeyPath)
        case segmentedControl(title: String, labels: [String], selectedIndex: (RuntimeObjectInterface.GenerationOptions) -> Int, mutation: (Int) -> OptionsMutation)

        static func enumOption<EnumType: CaseIterable & Equatable>(
            title: String,
            labels: [String],
            keyPath: WritableKeyPath<RuntimeObjectInterface.GenerationOptions, EnumType>
        ) -> OptionItem {
            .segmentedControl(
                title: title,
                labels: labels,
                selectedIndex: { Array(EnumType.allCases).firstIndex(of: $0[keyPath: keyPath]) ?? 0 },
                mutation: { index in { $0[keyPath: keyPath] = Array(EnumType.allCases)[index] } }
            )
        }
    }

    private struct Section {
        let title: String?
        let items: [OptionItem]
    }

    private lazy var sections: [Section] = [
        Section(title: "ObjC", items: [
            .checkbox(title: "Strip Protocol Conformance", keyPath: \.objcHeaderOptions.stripProtocolConformance),
            .checkbox(title: "Strip Overrides", keyPath: \.objcHeaderOptions.stripOverrides),
            .checkbox(title: "Strip Synthesized Ivars", keyPath: \.objcHeaderOptions.stripSynthesizedIvars),
            .checkbox(title: "Strip Synthesized Methods", keyPath: \.objcHeaderOptions.stripSynthesizedMethods),
            .checkbox(title: "Strip Ctor Method", keyPath: \.objcHeaderOptions.stripCtorMethod),
            .checkbox(title: "Strip Dtor Method", keyPath: \.objcHeaderOptions.stripDtorMethod),
            .checkbox(title: "Add Ivar Offset Comments", keyPath: \.objcHeaderOptions.addIvarOffsetComments),
            .checkbox(title: "Add Property Attributes Comments", keyPath: \.objcHeaderOptions.addPropertyAttributesComments),
            .checkbox(title: "Add Property Accessor Address Comments", keyPath: \.objcHeaderOptions.addPropertyAccessorAddressComments),
            .checkbox(title: "Add Method IMP Address Comments", keyPath: \.objcHeaderOptions.addMethodIMPAddressComments),
        ]),
        Section(title: "Swift", items: [
            .checkbox(title: "Print Stripped Symbol Description", keyPath: \.swiftInterfaceOptions.printStrippedSymbolicItem),
            .checkbox(title: "Print Field Offset", keyPath: \.swiftInterfaceOptions.printFieldOffset),
            .checkbox(title: "Print Expanded Field Offset", keyPath: \.swiftInterfaceOptions.printExpandedFieldOffset),
            .checkbox(title: "Print VTable Offset", keyPath: \.swiftInterfaceOptions.printVTableOffset),
            .checkbox(title: "Print PWT Offset", keyPath: \.swiftInterfaceOptions.printPWTOffset),
            .checkbox(title: "Print Member Address", keyPath: \.swiftInterfaceOptions.printMemberAddress),
            .checkbox(title: "Print Type Layout", keyPath: \.swiftInterfaceOptions.printTypeLayout),
            .checkbox(title: "Print Enum Layout", keyPath: \.swiftInterfaceOptions.printEnumLayout),
            .checkbox(title: "Synthesize Opaque Type (WIP)", keyPath: \.swiftInterfaceOptions.synthesizeOpaqueType),
            .enumOption(title: "Member Sort Order", labels: ["By Category", "By Offset"], keyPath: \.swiftInterfaceOptions.memberSortOrder),
        ]),
    ]

    private let generationOptionsLabel = Label("Generation Options")

    private lazy var stackView = VStackView(alignment: .left, spacing: 10) {
        generationOptionsLabel
    }

    private var checkboxMap: [OptionKeyPath: CheckboxButton] = [:]

    private var segmentedControlBindings: [(control: NSSegmentedControl, selectedIndex: (RuntimeObjectInterface.GenerationOptions) -> Int, mutation: (Int) -> OptionsMutation)] = []

    private let updateRelay = PublishRelay<OptionsMutation>()

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
                switch item {
                case .checkbox(let title, let keyPath):
                    let checkbox = CheckboxButton(title: title)
                    stackView.addArrangedSubview(checkbox)
                    checkboxMap[keyPath] = checkbox

                case .segmentedControl(let title, let labels, let selectedIndex, let mutation):
                    let titleLabel = Label(title)
                    let segmentedControl = NSSegmentedControl().then {
                        $0.segmentCount = labels.count
                        for (index, label) in labels.enumerated() {
                            $0.setLabel(label, forSegment: index)
                        }
                        $0.segmentStyle = .rounded
                        $0.selectedSegment = 0
                        $0.target = self
                        $0.action = #selector(segmentedControlChanged(_:))
                    }
                    let itemStack = HStackView(spacing: 8) {
                        titleLabel
                        segmentedControl
                    }
                    stackView.addArrangedSubview(itemStack)
                    segmentedControlBindings.append((control: segmentedControl, selectedIndex: selectedIndex, mutation: mutation))
                }
            }
        }

        preferredContentSize = stackView.fittingSize.inset(15)
    }

    @objc private func segmentedControlChanged(_ sender: NSSegmentedControl) {
        guard let binding = segmentedControlBindings.first(where: { $0.control === sender }) else { return }
        updateRelay.accept(binding.mutation(sender.selectedSegment))
    }

    override func setupBindings(for viewModel: GenerationOptionsViewModel<MainRoute>) {
        super.setupBindings(for: viewModel)

        for (keyPath, checkbox) in checkboxMap {
            checkbox.rx.state.asSignal()
                .map { state -> OptionsMutation in
                    let isOn = state == .on
                    return { $0[keyPath: keyPath] = isOn }
                }
                .emit(to: updateRelay)
                .disposed(by: rx.disposeBag)
        }

        let input = GenerationOptionsViewModel<MainRoute>.Input(
            updateOption: updateRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.options
            .driveOnNext { [weak self] options in
                guard let self else { return }
                for (keyPath, checkbox) in checkboxMap {
                    checkbox.state = options[keyPath: keyPath] ? .on : .off
                }
                for binding in segmentedControlBindings {
                    binding.control.selectedSegment = binding.selectedIndex(options)
                }
            }
            .disposed(by: rx.disposeBag)
    }
}

extension CGSize {
    fileprivate func inset(_ value: CGFloat) -> CGSize {
        return .init(width: width + value * 2, height: height + value * 2)
    }
}

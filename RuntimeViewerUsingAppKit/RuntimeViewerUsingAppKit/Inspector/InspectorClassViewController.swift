//
//  InspectorClassViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/7/6.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class InspectorClassViewModel: ViewModel<InspectorRoute> {
    @Observed
    private var runtimeClassName: String

    struct Input {}

    struct Output {
        let classHierarchy: Driver<String>
    }

    func transform(_ input: Input) -> Output {
        return Output(
            classHierarchy: $runtimeClassName.flatMapLatest { [unowned self] runtimeClassName in
                try await appServices.runtimeListings.runtimeObjectHierarchy(.class(named: runtimeClassName)).joined(separator: "\n")
            }.catchAndReturn(runtimeClassName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    init(runtimeClassName: String, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeClassName = runtimeClassName
        super.init(appServices: appServices, router: router)
    }
}

class InspectorDisclosureView<ContentView: NSView>: XiblessView {
    class HeaderView: XiblessView {
        let titleLabel = Label()

        let disclosureButton = Button()

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)
            hierarchy {
                titleLabel
                disclosureButton
            }
            titleLabel.snp.makeConstraints { make in
                make.top.left.equalToSuperview().inset(15)
                make.bottom.equalToSuperview()
            }

            disclosureButton.snp.makeConstraints { make in
                make.top.right.equalToSuperview().inset(15)
                make.left.greaterThanOrEqualTo(titleLabel.snp.right).offset(15)
            }

            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
            disclosureButton.title = "Hide"
            disclosureButton.alternateTitle = "Show"
            disclosureButton.setButtonType(.toggle)
            disclosureButton.contentTintColor = .secondaryLabelColor
            disclosureButton.font = .systemFont(ofSize: 12, weight: .bold)
            disclosureButton.isBordered = false

            disclosureButton.alphaValue = 0.0
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea(_:))

            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            disclosureButton.alphaValue = 1.0
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            disclosureButton.alphaValue = 0.0
        }
    }

    let headerView: HeaderView

    let contentView: ContentView

    var title: String = "" {
        didSet {
            headerView.titleLabel.stringValue = title
        }
    }

    init(contentView: ContentView) {
        self.headerView = HeaderView()
        self.contentView = contentView
        super.init(frame: .zero)
        hierarchy {
            headerView
            contentView
        }

        headerView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
        }

        setupContentViewConstraints(for: headerView.disclosureButton.state)

        print(headerView.disclosureButton.state.rawValue)

        headerView.disclosureButton.box.setAction { [weak self] button in
            guard let self, let button else { return }
            setupContentViewConstraints(for: button.state)
        }
    }

    func setupContentViewConstraints(for disclosureState: NSControl.StateValue) {
        contentView.snp.remakeConstraints { make in
            make.top.equalTo(headerView.snp.bottom).offset(15)
            make.left.bottom.equalToSuperview().inset(15)
            make.right.lessThanOrEqualToSuperview().inset(15)
            switch disclosureState {
            case .on:
                make.height.equalTo(0)
            default:
                break
            }
        }

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.2
            layoutSubtreeIfNeeded()
        }
    }
}

class InspectorClassHierarchyView: InspectorDisclosureView<Label> {
    var hierarchyString: String = "" {
        didSet {
            contentView.stringValue = hierarchyString
        }
    }

    init() {
        super.init(contentView: .init())
        title = "Hierarchy"
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.textColor = .controlTextColor
        contentView.font = .systemFont(ofSize: 12, weight: .regular)
    }
}

@available(macOS 14.0, *)
#Preview(traits: .fixedLayout(width: 500, height: 700)) {
    InspectorClassHierarchyView().then {
        $0.hierarchyString = "NSView\nNSResponder\nNSObject"
        $0.backgroundColor = .controlBackgroundColor
    }
}

class InspectorClassViewController: UXKitViewController<InspectorClassViewModel> {
    let classHierarchyView = InspectorClassHierarchyView()

    lazy var contentStackView = VStackView {
        classHierarchyView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
    }

    override func setupBindings(for viewModel: InspectorClassViewModel) {
        super.setupBindings(for: viewModel)

        let input = InspectorClassViewModel.Input()
        let output = viewModel.transform(input)
        output.classHierarchy.drive(classHierarchyView.contentView.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

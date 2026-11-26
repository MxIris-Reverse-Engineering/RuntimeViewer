import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCore
import RuntimeViewerSettings

/// The sheet Editor › Generation Options for “<image>”… opens: one image's Generation Options, the
/// overridden ones in bold with a button that puts them back on the global options (proposal
/// `generation-options-image-overrides`). The rows come from `RuntimeViewerSettings.Settings.GenerationOption`, the list
/// Settings › Generation Options is built from too.
final class ImageGenerationOptionsViewController: BaseViewController<ImageGenerationOptionsViewModel> {
    // MARK: - Rows

    /// One option's row: its control, and the button that reverts it.
    private final class OptionRow {
        let option: RuntimeViewerSettings.Settings.GenerationOption
        let view: NSView
        let revertButton: NSButton

        /// The checkbox of a toggle, or the segmented control of a choice with its title.
        let checkbox: CheckboxButton?
        let segmentedControl: NSSegmentedControl?
        let titleLabel: Label?

        init(option: RuntimeViewerSettings.Settings.GenerationOption) {
            self.option = option
            let revertButton = NSButton().then {
                $0.isBordered = false
                $0.bezelStyle = .accessoryBar
                $0.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Use the Global Value")
                $0.imagePosition = .imageOnly
                $0.toolTip = "Use the global value"
                $0.isHidden = true
            }
            self.revertButton = revertButton
            switch option.control {
            case .toggle:
                let checkbox = CheckboxButton(title: option.title)
                self.checkbox = checkbox
                segmentedControl = nil
                titleLabel = nil
                view = HStackView(spacing: 4) {
                    checkbox
                    revertButton
                }
            case .choice(let choice):
                let titleLabel = Label(option.title)
                let segmentedControl = NSSegmentedControl().then {
                    $0.segmentCount = choice.labels.count
                    for (index, label) in choice.labels.enumerated() {
                        $0.setLabel(label, forSegment: index)
                    }
                    $0.segmentStyle = .rounded
                    $0.selectedSegment = 0
                }
                checkbox = nil
                self.segmentedControl = segmentedControl
                self.titleLabel = titleLabel
                view = HStackView(spacing: 8) {
                    titleLabel
                    segmentedControl
                    revertButton
                }
            }
            if let stackView = view as? NSStackView {
                // NSStackView's default horizontal hugging (~250) loses to the outer stack's
                // cross-axis stretching, leaving this row's width ambiguous.
                stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
            }
        }

        /// Shows the image's value and whether the image overrides it.
        func apply(options: RuntimeObjectInterface.GenerationOptions, isOverridden: Bool) {
            let font: NSFont = isOverridden ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            switch option.control {
            case .toggle(let keyPath):
                checkbox?.state = options[keyPath: keyPath] ? .on : .off
                checkbox?.font = font
            case .choice(let choice):
                segmentedControl?.selectedSegment = choice.selectedIndex(options)
                titleLabel?.font = font
            }
            revertButton.isHidden = !isOverridden
        }

        /// The change the user's click on the control makes.
        func mutationForCurrentState() -> GenerationOptionsMutation? {
            switch option.control {
            case .toggle(let keyPath):
                guard let checkbox else { return nil }
                let isOn = checkbox.state == .on
                return { $0[keyPath: keyPath] = isOn }
            case .choice(let choice):
                guard let segmentedControl else { return nil }
                let selectedIndex = segmentedControl.selectedSegment
                return { choice.select(selectedIndex, &$0) }
            }
        }
    }

    // MARK: - Views

    private let titleLabel = Label().then {
        $0.font = .systemFont(ofSize: 15, weight: .semibold)
    }

    private let subtitleLabel = Label().then {
        $0.textColor = .secondaryLabelColor
    }

    private let revertAllButton = PushButton(title: "Revert All", titleFont: .systemFont(ofSize: 13))

    private let globalOptionsButton = PushButton(title: "Global Options…", titleFont: .systemFont(ofSize: 13))

    private let doneButton = PushButton(title: "Done", titleFont: .systemFont(ofSize: 13)).then {
        $0.keyEquivalent = "\r"
    }

    private lazy var rows: [OptionRow] = RuntimeViewerSettings.Settings.GenerationOption.allCases.map(OptionRow.init)

    private lazy var headerStack = VStackView(alignment: .leading, spacing: 2) {
        titleLabel
        subtitleLabel
    }

    private let optionsStack = VStackView(alignment: .leading, spacing: 10) {}

    /// The options scroll between the header and the buttons, so the sheet is never taller than
    /// the window it is on.
    private let optionsScrollView = ScrollView().then {
        $0.hasVerticalScroller = true
        $0.hasHorizontalScroller = false
        $0.autohidesScrollers = true
        $0.borderType = .noBorder
        $0.drawsBackground = false
    }

    private lazy var buttonBar = HStackView(spacing: 8) {
        revertAllButton
        globalOptionsButton
        NSView()
        doneButton
    }

    /// The scroll view's document: flipped, so the options start at the top.
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: - Layout

    /// The tallest the sheet may be, which the coordinator sets from the window it presents the
    /// sheet on before the view loads; `nil` for no limit. Options that do not fit scroll.
    var maximumContentHeight: CGFloat?

    private static let margin: CGFloat = 20

    private static let spacingAroundOptions: CGFloat = 12

    // MARK: - Relays

    /// The rows' controls are made from the option list, so their changes meet here.
    private let updateRelay = PublishRelay<GenerationOptionsMutation>()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        for section in RuntimeViewerSettings.Settings.GenerationOption.Section.allCases {
            optionsStack.addArrangedSubview(Label(section.title).then {
                $0.textColor = .secondaryLabelColor
            })
            for row in rows where row.option.section == section {
                optionsStack.addArrangedSubview(row.view)
                row.segmentedControl?.target = self
                row.segmentedControl?.action = #selector(segmentedControlChanged(_:))
            }
        }

        let documentView = DocumentView()
        documentView.hierarchy {
            optionsStack
        }
        optionsScrollView.documentView = documentView

        containerView.hierarchy {
            headerStack
            optionsScrollView
            buttonBar
        }

        headerStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(Self.margin)
        }

        optionsScrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(Self.spacingAroundOptions)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(buttonBar.snp.top).offset(-Self.spacingAroundOptions)
        }

        buttonBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(Self.margin)
        }

        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(optionsScrollView.contentView)
        }

        optionsStack.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(Self.margin)
        }

        preferredContentSize = fittingContentSize()
    }

    /// As large as the header, every option and the buttons need, but no taller than
    /// `maximumContentHeight`; a scroller that takes room gets it when the options scroll.
    private func fittingContentSize() -> CGSize {
        let headerSize = headerStack.fittingSize
        let optionsSize = optionsStack.fittingSize
        let buttonBarSize = buttonBar.fittingSize
        let naturalHeight = Self.margin + headerSize.height + Self.spacingAroundOptions + optionsSize.height + Self.spacingAroundOptions + buttonBarSize.height + Self.margin
        var width = max(headerSize.width, optionsSize.width, buttonBarSize.width) + Self.margin * 2
        guard let maximumContentHeight, naturalHeight > maximumContentHeight else {
            return CGSize(width: width, height: naturalHeight)
        }
        width += NSScroller.scrollerWidth(for: .regular, scrollerStyle: optionsScrollView.scrollerStyle)
        return CGSize(width: width, height: maximumContentHeight)
    }

    // MARK: - Actions

    @objc private func segmentedControlChanged(_ sender: NSSegmentedControl) {
        guard let row = rows.first(where: { $0.segmentedControl === sender }), let mutation = row.mutationForCurrentState() else { return }
        updateRelay.accept(mutation)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ImageGenerationOptionsViewModel) {
        super.setupBindings(for: viewModel)

        for row in rows {
            guard let checkbox = row.checkbox else { continue }
            checkbox.rx.click.asSignal()
                .compactMap { row.mutationForCurrentState() }
                .emit(to: updateRelay)
                .disposed(by: rx.disposeBag)
        }

        let input = ImageGenerationOptionsViewModel.Input(
            updateOption: updateRelay.asSignal(),
            revertOption: Signal.merge(rows.map { row in row.revertButton.rx.click.asSignal().map { row.option } }),
            revertAll: revertAllButton.rx.click.asSignal(),
            showGlobalOptions: globalOptionsButton.rx.click.asSignal(),
            done: doneButton.rx.click.asSignal()
        )

        let output = viewModel.transform(input)

        output.title.drive(titleLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.subtitle.drive(subtitleLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.canRevertAll.drive(revertAllButton.rx.isEnabled).disposed(by: rx.disposeBag)

        Driver.combineLatest(output.options, output.overriddenOptions)
            .driveOnNext { [weak self] options, overriddenOptions in
                guard let self else { return }
                for row in rows {
                    row.apply(options: options, isOverridden: overriddenOptions.contains(row.option))
                }
            }
            .disposed(by: rx.disposeBag)
    }
}

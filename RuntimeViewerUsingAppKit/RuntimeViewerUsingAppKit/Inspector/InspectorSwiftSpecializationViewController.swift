import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorSwiftSpecializationViewController: UXEffectViewController<InspectorSwiftSpecializationViewModel> {

    // MARK: - Relays

    private let addSpecializationRelay = PublishRelay<Void>()
    private let selectSpecializationRelay = PublishRelay<RuntimeObject>()

    // MARK: - Subviews

    private let headerLabel = Label()
    private let emptyLabel = Label()
    private let scrollView = ScrollView()
    private let tableView = NSTableView()
    private let addSpecializationButton = PushButton(
        title: "+ Add Specialization",
        titleFont: .systemFont(ofSize: 13)
    )

    // MARK: - State

    private var specializedChildren: [RuntimeObject] = []

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SpecializedChildCell")

    override var contentViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerLabel
            scrollView
            emptyLabel
            addSpecializationButton
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalTo(addSpecializationButton.snp.top).offset(-8)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        addSpecializationButton.snp.makeConstraints { make in
            make.bottom.trailing.equalToSuperview().inset(8)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("specialized"))
        column.title = "Type"
        column.minWidth = 120
        tableView.addTableColumn(column)

        tableView.do {
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.target = self
            $0.action = #selector(specializationRowClicked)
            $0.dataSource = self
            $0.delegate = self
            $0.rowHeight = 28
            $0.style = .plain
        }

        scrollView.do {
            $0.documentView = tableView
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .controlTextColor
        }

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.stringValue = "No specializations yet."
            $0.isHidden = true
        }

        addSpecializationButton.target = self
        addSpecializationButton.action = #selector(addSpecializationClicked)
    }

    // MARK: - Actions

    @objc private func addSpecializationClicked() {
        addSpecializationRelay.accept(())
    }

    @objc private func specializationRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < specializedChildren.count else { return }
        selectSpecializationRelay.accept(specializedChildren[row])
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: InspectorSwiftSpecializationViewModel) {
        super.setupBindings(for: viewModel)
        let input = InspectorSwiftSpecializationViewModel.Input(
            addSpecializationClicked: addSpecializationRelay.asSignal(),
            selectSpecializationClicked: selectSpecializationRelay.asSignal()
        )
        let output = viewModel.transform(input)

        let displayName = viewModel.runtimeObjectDisplayName
        headerLabel.stringValue = displayName.isEmpty
            ? "Specializations"
            : "Specializations of \(displayName)"

        output.specializedChildren.driveOnNext { [weak self] children in
            guard let self else { return }
            specializedChildren = children
            tableView.reloadData()
            emptyLabel.isHidden = !children.isEmpty
        }
        .disposed(by: rx.disposeBag)
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension InspectorSwiftSpecializationViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        specializedChildren.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < specializedChildren.count else { return nil }
        let cellView: NSTableCellView
        if let recycled = tableView.makeView(
            withIdentifier: InspectorSwiftSpecializationViewController.cellIdentifier,
            owner: nil
        ) as? NSTableCellView {
            cellView = recycled
        } else {
            cellView = NSTableCellView()
            cellView.identifier = InspectorSwiftSpecializationViewController.cellIdentifier
            let textField = Label()
            textField.font = .systemFont(ofSize: 13)
            textField.textColor = .controlTextColor
            cellView.textField = textField
            cellView.addSubview(textField)
            textField.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }
        cellView.textField?.stringValue = specializedChildren[row].displayName
        return cellView
    }
}

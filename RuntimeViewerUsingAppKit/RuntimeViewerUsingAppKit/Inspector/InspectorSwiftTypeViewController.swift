import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorSwiftTypeViewController: UXEffectViewController<InspectorSwiftTypeViewModel> {

    // MARK: - Relays

    private let addSpecializationRelay = PublishRelay<Void>()
    private let selectSpecializationRelay = PublishRelay<RuntimeObject>()

    // MARK: - Subviews

    private let segmentedControl = NSSegmentedControl()
    private let hierarchyContainer = NSView()
    private let specializationContainer = NSView()
    private let classHierarchyView = InspectorClassHierarchyView()

    private let specializationHeaderLabel = Label()
    private let specializationEmptyLabel = Label()
    private let specializationScrollView = ScrollView()
    private let specializationTableView = NSTableView()
    private let addSpecializationButton = PushButton(
        title: "+ Add Specialization",
        titleFont: .systemFont(ofSize: 13)
    )

    // MARK: - State

    private var specializedChildren: [RuntimeObject] = []
    private var currentVisibility = InspectorSwiftTypeViewModel.SegmentVisibility(
        showsHierarchy: false,
        showsSpecialization: false
    )

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SpecializedChildCell")

    override var contentViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            segmentedControl
            hierarchyContainer
            specializationContainer
        }

        hierarchyContainer.hierarchy {
            classHierarchyView
        }

        specializationContainer.hierarchy {
            specializationHeaderLabel
            specializationScrollView
            specializationEmptyLabel
            addSpecializationButton
        }

        segmentedControl.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(8)
        }

        hierarchyContainer.snp.makeConstraints { make in
            make.top.equalTo(segmentedControl.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }

        specializationContainer.snp.makeConstraints { make in
            make.edges.equalTo(hierarchyContainer)
        }

        classHierarchyView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        specializationHeaderLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(8)
        }

        specializationScrollView.snp.makeConstraints { make in
            make.top.equalTo(specializationHeaderLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalTo(addSpecializationButton.snp.top).offset(-8)
        }

        specializationEmptyLabel.snp.makeConstraints { make in
            make.center.equalTo(specializationScrollView)
        }

        addSpecializationButton.snp.makeConstraints { make in
            make.bottom.trailing.equalToSuperview().inset(8)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("specialized"))
        column.title = "Type"
        column.minWidth = 120
        specializationTableView.addTableColumn(column)

        specializationTableView.do {
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

        specializationScrollView.do {
            $0.documentView = specializationTableView
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        specializationHeaderLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .controlTextColor
        }

        specializationEmptyLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.stringValue = "No specializations yet."
            $0.isHidden = true
        }

        segmentedControl.do {
            $0.segmentStyle = .automatic
            $0.target = self
            $0.action = #selector(segmentChanged)
        }

        addSpecializationButton.target = self
        addSpecializationButton.action = #selector(addSpecializationClicked)
    }

    // MARK: - Actions

    @objc private func segmentChanged() {
        syncContainerVisibility()
    }

    @objc private func addSpecializationClicked() {
        addSpecializationRelay.accept(())
    }

    @objc private func specializationRowClicked() {
        let row = specializationTableView.clickedRow
        guard row >= 0, row < specializedChildren.count else { return }
        selectSpecializationRelay.accept(specializedChildren[row])
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: InspectorSwiftTypeViewModel) {
        super.setupBindings(for: viewModel)
        let input = InspectorSwiftTypeViewModel.Input(
            addSpecializationClicked: addSpecializationRelay.asSignal(),
            selectSpecializationClicked: selectSpecializationRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.hierarchy.drive(classHierarchyView.contentView.rx.stringValue).disposed(by: rx.disposeBag)

        output.specializedChildren.driveOnNext { [weak self] children in
            guard let self else { return }
            specializedChildren = children
            specializationTableView.reloadData()
            specializationEmptyLabel.isHidden = !children.isEmpty
        }
        .disposed(by: rx.disposeBag)

        output.segmentVisibility.driveOnNext { [weak self] visibility in
            guard let self else { return }
            updateSegments(for: visibility)
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Segment management

    private func updateSegments(for visibility: InspectorSwiftTypeViewModel.SegmentVisibility) {
        currentVisibility = visibility
        let titles = currentSegmentTitles()

        segmentedControl.segmentCount = titles.count
        for (index, title) in titles.enumerated() {
            segmentedControl.setLabel(title, forSegment: index)
            segmentedControl.setWidth(0, forSegment: index)
        }
        if !titles.isEmpty {
            segmentedControl.selectedSegment = 0
        }
        // A single-segment control would be visually noisy; hide it and let
        // the lone container fill the available space.
        segmentedControl.isHidden = titles.count <= 1

        syncContainerVisibility()
    }

    private func currentSegmentTitles() -> [String] {
        var titles: [String] = []
        if currentVisibility.showsHierarchy { titles.append("Hierarchy") }
        if currentVisibility.showsSpecialization { titles.append("Specialization") }
        return titles
    }

    private func syncContainerVisibility() {
        let titles = currentSegmentTitles()
        guard !titles.isEmpty else {
            hierarchyContainer.isHidden = true
            specializationContainer.isHidden = true
            return
        }
        // Anchor segmentedControl height regardless of visibility so the
        // container layout doesn't jump when the control toggles between
        // hidden (1 segment) and visible (2 segments).
        let selectedIndex = max(0, min(segmentedControl.selectedSegment, titles.count - 1))
        let activeTitle = titles[selectedIndex]
        hierarchyContainer.isHidden = activeTitle != "Hierarchy"
        specializationContainer.isHidden = activeTitle != "Specialization"

        if !specializationContainer.isHidden {
            updateSpecializationHeader()
        }
    }

    private func updateSpecializationHeader() {
        // The runtime object reference is stable for the lifetime of the VM
        // (a fresh VM is built whenever the user navigates to a different
        // node), so we read the display name directly instead of wiring
        // another driver for what is essentially static label text.
        let displayName = viewModel?.runtimeObjectDisplayName ?? ""
        specializationHeaderLabel.stringValue = displayName.isEmpty
            ? "Specializations"
            : "Specializations of \(displayName)"
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension InspectorSwiftTypeViewController: NSTableViewDataSource, NSTableViewDelegate {
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
            withIdentifier: InspectorSwiftTypeViewController.cellIdentifier,
            owner: nil
        ) as? NSTableCellView {
            cellView = recycled
        } else {
            cellView = NSTableCellView()
            cellView.identifier = InspectorSwiftTypeViewController.cellIdentifier
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

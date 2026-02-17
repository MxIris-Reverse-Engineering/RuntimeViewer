import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingSelectionViewController: AppKitViewController<ExportingSelectionViewModel> {
    // MARK: - Types

    private enum SelectionGroup: Int, CaseIterable {
        case objc = 0
        case swift = 1

        var title: String {
            switch self {
            case .objc: return "Objective-C"
            case .swift: return "Swift"
            }
        }
    }

    private enum SelectionItem {
        case group(SelectionGroup)
        case object(RuntimeObject)
    }

    // MARK: - Relays

    private let cancelRelay = PublishRelay<Void>()
    private let nextRelay = PublishRelay<Void>()
    private let toggleObjectRelay = PublishRelay<RuntimeObject>()
    private let toggleAllObjCRelay = PublishRelay<Bool>()
    private let toggleAllSwiftRelay = PublishRelay<Bool>()

    // MARK: - State

    private var items: [SelectionItem] = []
    private var objcObjects: [RuntimeObject] = []
    private var swiftObjects: [RuntimeObject] = []
    private var selectedObjects: Set<RuntimeObject> = []

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = ScrollView()
    private let summaryLabel = Label()
    private let nextButton = PushButton()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        let iconImageView = ImageView().then {
            $0.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            $0.symbolConfiguration = .init(pointSize: 32, weight: .light)
            $0.contentTintColor = .controlAccentColor
        }

        let titleLabel = Label("Export Interfaces").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
        }

        let headerStack = HStackView(spacing: 10) {
            iconImageView
            titleLabel
        }.then {
            $0.alignment = .centerY
        }

        let column = NSTableColumn(identifier: .init("main"))
        column.title = ""
        tableView.do {
            $0.addTableColumn(column)
            $0.headerView = nil
            $0.dataSource = self
            $0.delegate = self
            $0.selectionHighlightStyle = .none
            $0.rowHeight = 24
            $0.intercellSpacing = NSSize(width: 0, height: 2)
        }

        scrollView.do {
            $0.documentView = tableView
            $0.hasVerticalScroller = true
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        nextButton.do {
            $0.title = "Next"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(nextClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            cancelButton
            nextButton
        }

        view.hierarchy {
            headerStack
            scrollView
            summaryLabel
            buttonStack
        }

        headerStack.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalTo(summaryLabel.snp.top).offset(-8)
        }

        summaryLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(20)
            make.bottom.equalTo(buttonStack.snp.top).offset(-12)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelRelay.accept(())
    }

    @objc private func nextClicked() {
        nextRelay.accept(())
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        switch item {
        case .group(let group):
            let nextState: Bool = sender.state != .off
            switch group {
            case .objc: toggleAllObjCRelay.accept(nextState)
            case .swift: toggleAllSwiftRelay.accept(nextState)
            }
        case .object(let object):
            toggleObjectRelay.accept(object)
        }
    }

    // MARK: - Data

    private func rebuildItems() {
        items = []
        if !objcObjects.isEmpty {
            items.append(.group(.objc))
            items += objcObjects.map { .object($0) }
        }
        if !swiftObjects.isEmpty {
            items.append(.group(.swift))
            items += swiftObjects.map { .object($0) }
        }
        tableView.reloadData()
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ExportingSelectionViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingSelectionViewModel.Input(
            cancelClick: cancelRelay.asSignal(),
            nextClick: nextRelay.asSignal(),
            toggleObject: toggleObjectRelay.asSignal(),
            toggleAllObjC: toggleAllObjCRelay.asSignal(),
            toggleAllSwift: toggleAllSwiftRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.objcObjects.driveOnNext { [weak self] objects in
            guard let self else { return }
            self.objcObjects = objects
            rebuildItems()
        }
        .disposed(by: rx.disposeBag)

        output.swiftObjects.driveOnNext { [weak self] objects in
            guard let self else { return }
            self.swiftObjects = objects
            rebuildItems()
        }
        .disposed(by: rx.disposeBag)

        output.selectedObjects.driveOnNext { [weak self] selected in
            guard let self else { return }
            self.selectedObjects = selected
            tableView.reloadData()
        }
        .disposed(by: rx.disposeBag)

        output.summaryText.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.isNextEnabled.driveOnNext { [weak self] enabled in
            guard let self else { return }
            nextButton.isEnabled = enabled
        }
        .disposed(by: rx.disposeBag)
    }
}

// MARK: - NSTableViewDataSource

extension ExportingSelectionViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

// MARK: - NSTableViewDelegate

extension ExportingSelectionViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        switch item {
        case .group(let group):
            let objects = group == .objc ? objcObjects : swiftObjects
            let selectedCount = objects.filter { selectedObjects.contains($0) }.count

            let checkbox = NSButton(checkboxWithTitle: "\(group.title) (\(objects.count))", target: self, action: #selector(checkboxClicked(_:)))
            checkbox.font = .systemFont(ofSize: 13, weight: .semibold)
            checkbox.tag = row
            checkbox.allowsMixedState = true
            checkbox.state = selectedCount == 0 ? .off : (selectedCount == objects.count ? .on : .mixed)

            let container = NSView()
            container.addSubview(checkbox)
            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(4)
                make.centerY.equalToSuperview()
            }
            return container

        case .object(let object):
            let checkbox = NSButton(checkboxWithTitle: object.displayName, target: self, action: #selector(checkboxClicked(_:)))
            checkbox.font = .systemFont(ofSize: 13)
            checkbox.tag = row
            checkbox.state = selectedObjects.contains(object) ? .on : .off

            let container = NSView()
            container.addSubview(checkbox)
            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(24)
                make.centerY.equalToSuperview()
            }
            return container
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .group: return 28
        case .object: return 22
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}

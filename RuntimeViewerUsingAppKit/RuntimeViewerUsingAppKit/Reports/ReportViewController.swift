import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// The Report navigator page, laid out after Xcode 26's — proposal `draft-report-navigator`.
/// Like Xcode's: one source-list outline of 24-point rows, the kinds of work as first-level rows,
/// each piece of work under its kind with a spinner while it runs; and the 44-point bar at the
/// bottom with an actions button and a filter field whose clock toggle keeps only the work in
/// progress. Unlike Xcode's, selecting a row opens nothing: the reports have no page of their own.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both bind the
/// document's coordinators through their own `ReportViewModel`.
final class ReportViewController<Route: Routable>: BaseEffectViewController<ReportViewModel<Route>>, NSMenuDelegate {
    // MARK: - Relays

    /// The page has no control whose accessor says "came on screen".
    private let appearedRelay = PublishRelay<Void>()

    /// The actions menu and the context menu are built on demand, so their items report here.
    private let cancelRelay = PublishRelay<ReportNode>()

    private let cancelAllRelay = PublishRelay<Void>()

    private let clearHistoryRelay = PublishRelay<Void>()

    private let openSettingsRelay = PublishRelay<Void>()

    // MARK: - Outline

    private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    private let emptyLabel = Label("No Reports")

    // MARK: - Filter Bar

    private let bottomSeparatorView = NSBox()

    private let actionsButton = NSButton()

    private let filterSearchField = FilterSearchField()

    private var showsOnlyInProgressButton: NSButton!

    private lazy var filterStackView = HStackView(distribution: .fill, alignment: .fill, spacing: 6) {
        actionsButton
        filterSearchField
    }

    private var hasWorkInProgress = false

    private var hasHistory = false

    override var containerViewUsingSafeArea: Bool { true }

    /// The outline takes keyboard focus when the sidebar shows this page, like the other sidebar
    /// lists — see `SidebarRootViewController.preferredFirstResponder`.
    override var preferredFirstResponder: NSResponder? {
        outlineView.window != nil ? outlineView : nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        showsOnlyInProgressButton = filterSearchField.addFilterButton(
            systemSymbolName: "clock",
            toolTip: "Show only reports in progress"
        )

        containerView.hierarchy {
            scrollView
            emptyLabel
            bottomSeparatorView
            filterStackView
        }

        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(bottomSeparatorView.snp.top)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }

        bottomSeparatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
            make.bottom.equalTo(filterStackView.snp.top).offset(-8)
        }

        showsOnlyInProgressButton.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
        }

        filterStackView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(8)
        }

        bottomSeparatorView.boxType = .separator

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .center
            $0.isHidden = true
        }

        scrollView.do {
            $0.borderType = .noBorder
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.hasHorizontalScroller = false
            $0.autohidesScrollers = true
            $0.hidesVisualEffectView = true
        }

        outlineView.do {
            $0.style = .sourceList
            $0.indentationPerLevel = 14
            $0.indentationMarkerFollowsCell = true
            $0.intercellSpacing = NSSize(width: 3, height: 0)
            $0.rowHeight = 24
            $0.usesAutomaticRowHeights = false
            $0.floatsGroupRows = true
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.allowsTypeSelect = true
            // The newest work is inserted at the top; the highlight stays on the row it was on.
            $0.preservesSelectedItemAcrossReloads = true
            $0.headerView = nil
            $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            $0.target = self
            $0.doubleAction = #selector(outlineViewDoubleClicked(_:))
            $0.menu = NSMenu().then {
                $0.delegate = self
            }
        }

        actionsButton.do {
            $0.isBordered = false
            $0.imagePosition = .imageOnly
            $0.image = SFSymbols(systemName: .ellipsisCircle).nsuiImgae
            $0.toolTip = "Report Actions"
            $0.target = self
            $0.action = #selector(actionsButtonClicked(_:))
        }

        filterSearchField.do {
            if #available(macOS 26.0, *) {
                $0.controlSize = .extraLarge
            } else {
                $0.controlSize = .large
            }
            $0.toolTip = "Show reports with matching name"
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        appearedRelay.accept(())
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ReportViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let input = ReportViewModel<Route>.Input(
            appeared: appearedRelay.asSignal(),
            cancel: cancelRelay.asSignal(),
            cancelAll: cancelAllRelay.asSignal(),
            clearHistory: clearHistoryRelay.asSignal(),
            openSettings: openSettingsRelay.asSignal(),
            filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
            showsOnlyInProgress: showsOnlyInProgressButton.rx.state.asDriver().map { $0 == .on }.startWith(false)
        )
        let output = viewModel.transform(input)

        output.nodes.drive(outlineView.rx.nodes(options: []))({ (outlineView: NSOutlineView, _: NSTableColumn?, node: ReportNode) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: ReportCellView.self)
            cellView.bind(to: node.cellViewModel)
            return cellView
        }, { outlineView, _ -> NSTableRowView? in
            if #available(macOS 26.0, *) {
                return outlineView.box.makeView(ofClass: SidebarTableRowView.self)
            } else {
                return nil
            }
        })
        .disposed(by: rx.disposeBag)

        // Subscribed after the nodes binding, so the adapter has reloaded by the time this runs:
        // each kind of work, and whatever runs under it, is shown open, as Xcode opens the
        // newest builds; what the user collapses or opens otherwise stays as it is.
        output.nodes.driveOnNext { [weak self] nodes in
            guard let self else { return }
            for categoryNode in nodes {
                if !outlineView.isItemExpanded(categoryNode) {
                    outlineView.expandItem(categoryNode)
                }
                for node in categoryNode.children where node.cellViewModel.isInProgress && !node.children.isEmpty {
                    if !outlineView.isItemExpanded(node) {
                        outlineView.expandItem(node)
                    }
                }
            }
        }
        .disposed(by: rx.disposeBag)

        output.isEmpty.driveOnNext { [weak self] isEmpty in
            guard let self else { return }
            emptyLabel.isHidden = !isEmpty
            scrollView.isHidden = isEmpty
        }
        .disposed(by: rx.disposeBag)

        output.hasWorkInProgress.driveOnNext { [weak self] hasWorkInProgress in
            self?.hasWorkInProgress = hasWorkInProgress
        }
        .disposed(by: rx.disposeBag)

        output.hasHistory.driveOnNext { [weak self] hasHistory in
            self?.hasHistory = hasHistory
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Actions

    @objc private func actionsButtonClicked(_ sender: NSButton) {
        let menu = NSMenu().then { menu in
            menu.addItem(withTitle: "Cancel All", action: hasWorkInProgress ? #selector(cancelAllMenuItemAction(_:)) : nil, keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .xmarkCircle).nsImage
            }
            menu.addItem(withTitle: "Clear History", action: hasHistory ? #selector(clearHistoryMenuItemAction(_:)) : nil, keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .trash).nsImage
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Open Settings…", action: #selector(openSettingsMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .gearshape).nsImage
            }
        }
        menu.autoenablesItems = false
        for item in menu.items {
            item.isEnabled = item.action != nil
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func cancelAllMenuItemAction(_ sender: NSMenuItem) {
        cancelAllRelay.accept(())
    }

    @objc private func clearHistoryMenuItemAction(_ sender: NSMenuItem) {
        clearHistoryRelay.accept(())
    }

    @objc private func openSettingsMenuItemAction(_ sender: NSMenuItem) {
        openSettingsRelay.accept(())
    }

    @objc private func cancelMenuItemAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        cancelRelay.accept(node)
    }

    /// A feature's "turned off" row opens Settings, where it is turned back on.
    @objc private func outlineViewDoubleClicked(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? ReportNode else { return }
        if case .turnedOff = node.identifier {
            openSettingsRelay.accept(())
        }
    }

    // MARK: - Context Menu

    /// Built when it opens, for the clicked row: Cancel while that work can still be withdrawn,
    /// Open Settings on a feature's "turned off" row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outlineView.clickedRow >= 0, let node = outlineView.item(atRow: outlineView.clickedRow) as? ReportNode else { return }
        if node.cellViewModel.isCancellable {
            menu.addItem(withTitle: "Cancel", action: #selector(cancelMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.representedObject = node
                $0.image = SFSymbols(systemName: .xmarkCircle).nsImage
            }
        }
        if case .turnedOff = node.identifier {
            menu.addItem(withTitle: "Open Settings…", action: #selector(openSettingsMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .gearshape).nsImage
            }
        }
    }
}

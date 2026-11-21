import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// An editor pane with nothing open: the start page — Xcode 27.2's initial editor, an Open Quickly
/// field over the engine's recent objects (proposal `editor-start-page`) — or, while the window's
/// file is still being read, a spinner that says so.
final class ContentPlaceholderViewController: BaseViewController<ContentPlaceholderViewModel> {
    // MARK: - Relays

    private let recentItemOpenedRelay = PublishRelay<ContentPlaceholderViewModel.ItemOpening>()

    // MARK: - Start Page

    private let startPageView = NSView()

    private let searchField = OpenQuicklyField().then {
        $0.placeholderString = "Open Quickly"
    }

    private let recentItemsTitleLabel = Label("Recent Objects").then {
        $0.font = .preferredFont(forTextStyle: .title1)
        $0.textColor = .labelColor
    }

    private let showAllButton = NSButton(title: "", target: nil, action: nil).then {
        $0.isBordered = false
        $0.setButtonType(.momentaryChange)
        $0.isHidden = true
    }

    private let (recentItemsScrollView, recentItemsTableView): (ScrollView, RecentItemsTableView) = RecentItemsTableView.scrollableTableView()

    /// The recent objects the list shows, as last applied: what each row stands for, which the
    /// table itself forgets — it keeps a selection by row, and a list reordered by another window
    /// would otherwise leave it on whatever object moved into that row.
    private var shownRecentItems: [ContentStartPageItemCellViewModel] = []

    // MARK: - Reading a File

    private let readingIndicator = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .regular
        $0.isDisplayedWhenStopped = false
    }

    private let readingLabel = Label().then {
        $0.font = .systemFont(ofSize: 20, weight: .regular)
        $0.textColor = .secondaryLabelColor
    }

    private lazy var readingStackView = VStackView(alignment: .center, spacing: 12) {
        readingIndicator
        readingLabel
    }

    override var containerViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            startPageView
            readingStackView
        }

        startPageView.hierarchy {
            searchField
            recentItemsTitleLabel
            showAllButton
            recentItemsScrollView
        }

        startPageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        readingStackView.snp.makeConstraints { make in
            make.center.equalTo(containerView)
        }

        // One centred column, 200 to 700 points wide, 32 points from either side of the page.
        searchField.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(Metrics.pageTopInset)
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().offset(-2 * Metrics.pageHorizontalInset).priority(.high)
            make.width.lessThanOrEqualTo(Metrics.maximumColumnWidth)
            make.width.greaterThanOrEqualTo(Metrics.minimumColumnWidth)
        }

        recentItemsTitleLabel.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(Metrics.sectionTopSpacing)
            make.leading.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
        }

        showAllButton.snp.makeConstraints { make in
            make.firstBaseline.equalTo(recentItemsTitleLabel)
            make.leading.greaterThanOrEqualTo(recentItemsTitleLabel.snp.trailing).offset(Metrics.sectionHorizontalInset)
            make.trailing.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
        }

        recentItemsScrollView.snp.makeConstraints { make in
            make.top.equalTo(recentItemsTitleLabel.snp.bottom).offset(Metrics.listTopSpacing)
            make.leading.equalTo(searchField).inset(Metrics.sectionHorizontalInset + Metrics.listLeadingInset)
            make.trailing.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
            make.bottom.equalToSuperview()
        }

        recentItemsScrollView.do {
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.autohidesScrollers = true
        }

        recentItemsTableView.do {
            $0.headerView = nil
            $0.backgroundColor = .clear
            $0.style = .plain
            $0.rowHeight = Metrics.rowHeight
            $0.intercellSpacing = .zero
            $0.gridStyleMask = []
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
        }
        recentItemsTableView.returnKeyPressed = { [weak self] row, modifierFlags in
            guard let self else { return }
            openRecentItem(atRow: row, modifierFlags: modifierFlags)
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ContentPlaceholderViewModel) {
        super.setupBindings(for: viewModel)

        recentItemsTableView.rx.itemDoubleClicked()
            .asSignal()
            .emitOnNext { [weak self] index in
                guard let self else { return }
                openRecentItem(atRow: index.row, modifierFlags: NSApp.currentEvent?.modifierFlags ?? [])
            }
            .disposed(by: rx.disposeBag)

        let input = ContentPlaceholderViewModel.Input(
            pageWillAppear: rx.viewWillAppear.asSignal(),
            showAllClicked: showAllButton.rx.click.asSignal(),
            recentItemOpened: recentItemOpenedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.placeholder.driveOnNext { [weak self] placeholder in
            guard let self else { return }
            switch placeholder {
            case .noSelection:
                startPageView.isHidden = false
                readingStackView.isHidden = true
                readingIndicator.stopAnimation(nil)
            case .readingFile(let name):
                resignFocus(within: startPageView)
                startPageView.isHidden = true
                readingStackView.isHidden = false
                readingLabel.stringValue = "Reading “\(name)”…"
                readingIndicator.startAnimation(nil)
            }
        }
        .disposed(by: rx.disposeBag)

        // Three subscriptions to one driver, in this order on purpose: a driver delivers to its
        // subscribers in the order they subscribed, and `rx.items` applies each list to the table
        // there and then. So the first sees the table still showing the previous list, and the
        // last sees it showing the new one.
        var recentItemSelectedBeforeUpdate: ContentStartPageItemCellViewModel.Item?
        output.recentItems.driveOnNext { [weak self] _ in
            guard let self else { return }
            let selectedRow = recentItemsTableView.selectedRow
            recentItemSelectedBeforeUpdate = shownRecentItems.indices.contains(selectedRow) ? shownRecentItems[selectedRow].item : nil
        }
        .disposed(by: rx.disposeBag)

        output.recentItems
            .drive(recentItemsTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: ContentStartPageItemCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: ItemCellView.self)
                cellView.configure(with: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.recentItems.driveOnNext { [weak self] recentItems in
            guard let self else { return }
            shownRecentItems = recentItems
            recentItemsTitleLabel.isHidden = recentItems.isEmpty
            recentItemsScrollView.isHidden = recentItems.isEmpty
            // The selection follows its object, wherever the new list puts it; an object the list
            // let go of — Show Less hides it — leaves the focused list on its first row, so that
            // Return still has something to open.
            if let selectedItem = recentItemSelectedBeforeUpdate, let row = recentItems.firstIndex(where: { $0.item == selectedItem }) {
                if row != recentItemsTableView.selectedRow {
                    recentItemsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else {
                recentItemsTableView.deselectAll(nil)
                recentItemsTableView.selectFirstRowIfFocusedWithoutSelection()
            }
        }
        .disposed(by: rx.disposeBag)

        output.startedOver.emitOnNext { [weak self] in
            guard let self else { return }
            recentItemsTableView.deselectAll(nil)
        }
        .disposed(by: rx.disposeBag)

        output.showAllButton.driveOnNext { [weak self] button in
            guard let self else { return }
            showAllButton.isHidden = button.title == nil
            showAllButton.attributedTitle = NSAttributedString(
                string: button.title ?? "",
                attributes: [
                    .font: NSFont.systemFont(ofSize: Metrics.showAllFontSize),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Actions

    /// Opens the recent object in `row` where the modifier keys say: a list's double-click or
    /// Return opens in the pane's tab, with ⌥ in the next pane, with ⇧⌥ in a new tab.
    private func openRecentItem(atRow row: Int, modifierFlags: NSEvent.ModifierFlags) {
        guard (0 ..< recentItemsTableView.numberOfRows).contains(row),
              let item: ContentStartPageItemCellViewModel = try? recentItemsTableView.rx.model(at: row)
        else { return }
        recentItemOpenedRelay.accept(.init(item: item, destination: SelectionRoute.Destination(listClickModifierFlags: modifierFlags)))
    }

    /// Takes the keyboard focus away from `containerView` when a view inside it — the field's field
    /// editor included — has it, so that keys typed after it is hidden go nowhere unseen.
    private func resignFocus(within containerView: NSView) {
        guard let window = view.window,
              let firstResponder = window.firstResponder as? NSView,
              firstResponder.isDescendant(of: containerView)
        else { return }
        window.makeFirstResponder(nil)
    }
}

// MARK: - Metrics

extension ContentPlaceholderViewController {
    /// The start page's measurements: Xcode 27.2's initial editor (`InitialEditorView`,
    /// `RecentItemsSection`, `RecentItemView` in IDEKit; the proposal lists the addresses).
    fileprivate enum Metrics {
        static let pageTopInset: CGFloat = 80
        static let pageHorizontalInset: CGFloat = 32
        static let minimumColumnWidth: CGFloat = 200
        static let maximumColumnWidth: CGFloat = 700
        static let sectionTopSpacing: CGFloat = 65
        static let sectionHorizontalInset: CGFloat = 4
        static let listLeadingInset: CGFloat = 4
        static let listTopSpacing: CGFloat = 12
        static let showAllFontSize: CGFloat = 11
        /// SwiftUI's `List` row around a 32-point icon beside two lines of text, as Xcode draws it.
        static let rowHeight: CGFloat = 38
        static let rowVerticalInset: CGFloat = 3
        static let rowTrailingInset: CGFloat = 4
        static let iconToTextSpacing: CGFloat = 4
        static let titleFontSize: CGFloat = 13
        static let pathFontSize: CGFloat = 11
        static let pathIconSide: CGFloat = 12
        static let pathIconFrameHeight: CGFloat = 14
        static let pathIconToTextSpacing: CGFloat = 2
    }
}

// MARK: - Recent Items Table

extension ContentPlaceholderViewController {
    /// The recent objects' list. As in Xcode's, a click only selects; Return opens the selected row,
    /// as a double-click does, and taking the focus from the keyboard with nothing selected selects
    /// the first row.
    fileprivate final class RecentItemsTableView: SingleColumnTableView {
        /// Return on the selected row, with the modifier keys held.
        var returnKeyPressed: ((_ row: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Void)?

        /// Keeps AppKit from installing its table gesture recognizers, so that a click takes the
        /// keyboard focus as it did before macOS 27: there a click on a row only selects it, the
        /// focus stays in the Open Quickly field, the row shows in the unfocused grey and Return
        /// goes to the field instead of opening the row. `StatefulOutlineView` keeps the same
        /// override for the same reason (`RuntimeViewerUsingAppKit/AGENTS.md`, *Diagnosing UI
        /// Flicker*); AppKit logs that gesture recognizer support is disabled for this class.
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let modifierFlags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if Self.returnKeyCodes.contains(event.keyCode), modifierFlags.isSubset(of: [.option, .shift]), selectedRow >= 0 {
                returnKeyPressed?(selectedRow, modifierFlags)
                return
            }
            super.keyDown(with: event)
        }

        /// Only a focus taken from the keyboard selects the first row: a click takes the focus
        /// before it selects the clicked row, and selecting the first row in between would show it
        /// for a frame.
        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder, NSApp.currentEvent?.type == .keyDown {
                selectFirstRowIfFocusedWithoutSelection()
            }
            return didBecomeFirstResponder
        }

        /// Selects the first row while the list has the keyboard focus and nothing selected.
        func selectFirstRowIfFocusedWithoutSelection() {
            guard window?.firstResponder === self, selectedRow < 0, numberOfRows > 0 else { return }
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        /// Return (36) and the keypad's Enter (76).
        private static let returnKeyCodes: Set<UInt16> = [36, 76]
    }
}

// MARK: - Open Quickly Field

extension ContentPlaceholderViewController {
    /// The large rounded query field at the top of the start page: Xcode 27.2's initial editor shows
    /// Open Quickly's query field there (`IDESearchWindowQueryView` in IDEKit's `IDEInitialEditor`),
    /// a magnifying glass followed by the text, in a capsule whose ring lights up with the accent
    /// colour while the field is being typed in, in a key window.
    ///
    /// The view only draws the field. The controller reads and clears `textField`, and takes its
    /// commands — the arrow keys, Return, Escape — as the text field's delegate.
    private final class OpenQuicklyField: LayerBackedView {
        /// The text typed into the field.
        var textField: NSTextField { focusReportingTextField }

        /// What the field says while it is empty.
        var placeholderString: String = "" {
            didSet { updatePlaceholder() }
        }

        private let focusReportingTextField = FocusReportingTextField()

        private let magnifyingGlassView = ImageView()

        /// Whether the field is being typed in.
        private var isEditing = false {
            didSet {
                guard isEditing != oldValue else { return }
                updateRing()
            }
        }

        /// Follows whether the field's window is key; replaced when the field moves to another
        /// window, and gone with the field.
        private var windowKeyObservation: WindowKeyObservation?

        override func setup() {
            super.setup()

            cornerRadius = OpenQuicklyFieldMetrics.height / 2
            borderWidth = OpenQuicklyFieldMetrics.ringWidth
            borderPositions = .all
            backgroundColor = .clear
            updateRing()

            magnifyingGlassView.do {
                $0.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                $0.symbolConfiguration = .init(pointSize: OpenQuicklyFieldMetrics.magnifyingGlassPointSize, weight: .regular)
                $0.contentTintColor = .secondaryLabelColor
                $0.setAccessibilityElement(false)
            }

            focusReportingTextField.focusDidChange = { [weak self] isEditing in
                guard let self else { return }
                self.isEditing = isEditing
            }

            hierarchy {
                magnifyingGlassView
                focusReportingTextField
            }

            magnifyingGlassView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(OpenQuicklyFieldMetrics.magnifyingGlassLeadingInset)
                make.centerY.equalToSuperview()
            }

            focusReportingTextField.snp.makeConstraints { make in
                make.leading.equalTo(magnifyingGlassView.snp.trailing).offset(OpenQuicklyFieldMetrics.textLeadingSpacing)
                make.trailing.equalToSuperview().inset(OpenQuicklyFieldMetrics.textTrailingInset)
                make.centerY.equalToSuperview()
            }

            snp.makeConstraints { make in
                make.height.equalTo(OpenQuicklyFieldMetrics.height)
            }

            updatePlaceholder()
        }

        /// A click anywhere on the capsule types into the field; a click while it is being typed in
        /// leaves the text and the insertion point alone.
        override func mouseDown(with event: NSEvent) {
            guard focusReportingTextField.currentEditor() == nil else { return }
            window?.makeFirstResponder(focusReportingTextField)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowKeyObservation = window.map { window in
                WindowKeyObservation(window: window) { [weak self] in
                    guard let self else { return }
                    updateRing()
                }
            }
            updateRing()
        }

        /// The ring is the accent colour while the field is typed in in the key window, and a faint
        /// line otherwise.
        private func updateRing() {
            let isRingLit = isEditing && window?.isKeyWindow == true
            borderColor = isRingLit ? NSColor.controlAccentColor.withAlphaComponent(OpenQuicklyFieldMetrics.litRingOpacity) : .quaternaryLabelColor
        }

        private func updatePlaceholder() {
            focusReportingTextField.placeholderAttributedString = NSAttributedString(
                string: placeholderString,
                attributes: [
                    .font: NSFont.systemFont(ofSize: OpenQuicklyFieldMetrics.fontSize, weight: .regular),
                    .foregroundColor: NSColor.placeholderTextColor,
                ]
            )
        }
    }

    /// Calls `keyStateDidChange` on the main actor whenever `window` becomes or stops being the key
    /// window, for as long as the observation lives: the observers go when it does, whichever way
    /// its owner goes.
    private final class WindowKeyObservation {
        private let observers: [NSObjectProtocol]

        init(window: NSWindow, keyStateDidChange: @escaping @MainActor () -> Void) {
            observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { notificationName in
                NotificationCenter.default.addObserver(forName: notificationName, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        keyStateDidChange()
                    }
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// The query field's measurements, after Xcode 27.2's initial editor.
    fileprivate enum OpenQuicklyFieldMetrics {
        static let height: CGFloat = 46
        static let ringWidth: CGFloat = 3
        static let litRingOpacity: CGFloat = 0.45
        static let fontSize: CGFloat = 20
        static let magnifyingGlassPointSize: CGFloat = 19
        static let magnifyingGlassLeadingInset: CGFloat = 20
        static let textLeadingSpacing: CGFloat = 20
        static let textTrailingInset: CGFloat = 20
    }

    /// A borderless text field that says when typing in it starts and ends: the field editor takes
    /// the first responder over as soon as the field gets it, so the field itself only hears both
    /// ends. It neither hugs nor resists its width, so the capsule's width alone decides it.
    private final class FocusReportingTextField: TextField {
        var focusDidChange: ((Bool) -> Void)?

        override func setup() {
            super.setup()
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            isEditable = true
            isSelectable = true
            usesSingleLineMode = true
            lineBreakMode = .byTruncatingTail
            cell?.isScrollable = true
            cell?.wraps = false
            font = .systemFont(ofSize: OpenQuicklyFieldMetrics.fontSize, weight: .regular)
            textColor = .labelColor
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder {
                focusDidChange?(true)
            }
            return didBecomeFirstResponder
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            focusDidChange?(false)
        }
    }
}

// MARK: - Item Cell

extension ContentPlaceholderViewController {
    /// A row of the start page, as Xcode's initial editor draws a recent file: the item's 32-point
    /// icon, and beside it its name and, under the name, its path — the first component's icon,
    /// then the components joined with a compact chevron — over a hairline that starts under the
    /// text.
    fileprivate final class ItemCellView: TableCellView {
        private let iconView = ImageView()

        private let titleLabel = Label().then {
            $0.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingMiddle
            $0.maximumNumberOfLines = 1
        }

        private let pathIconView = ImageView()

        private let pathLabel = Label().then {
            $0.font = .systemFont(ofSize: Metrics.pathFontSize, weight: .regular)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingMiddle
            $0.maximumNumberOfLines = 1
        }

        private let separatorView = HorizontalSeparatorView()

        override func setup() {
            super.setup()

            let pathStackView = HStackView(alignment: .top, spacing: Metrics.pathIconToTextSpacing) {
                pathIconView
                pathLabel
            }

            let textStackView = VStackView(alignment: .leading, spacing: 1) {
                titleLabel
                pathStackView
            }

            hierarchy {
                iconView
                textStackView
                separatorView
            }

            iconView.snp.makeConstraints { make in
                make.leading.equalToSuperview()
                make.top.equalToSuperview().inset(Metrics.rowVerticalInset)
                make.size.equalTo(ContentStartPageItemCellViewModel.iconSize)
            }

            pathIconView.snp.makeConstraints { make in
                make.width.equalTo(Metrics.pathIconSide)
                make.height.equalTo(Metrics.pathIconFrameHeight)
            }

            textStackView.snp.makeConstraints { make in
                make.leading.equalTo(iconView.snp.trailing).offset(Metrics.iconToTextSpacing)
                make.trailing.lessThanOrEqualToSuperview().inset(Metrics.rowTrailingInset)
                make.top.equalToSuperview().inset(Metrics.rowVerticalInset)
            }

            separatorView.snp.makeConstraints { make in
                make.leading.equalTo(textStackView)
                make.trailing.equalToSuperview()
                make.bottom.equalToSuperview()
            }
        }

        func configure(with cellViewModel: ContentStartPageItemCellViewModel) {
            let appearance = cellViewModel.appearance
            iconView.image = appearance.icon.image(size: ContentStartPageItemCellViewModel.iconSize)
            titleLabel.stringValue = appearance.title
            pathIconView.image = appearance.pathIcon?.image(size: Metrics.pathIconSide)
            pathIconView.isHidden = appearance.pathIcon == nil
            pathLabel.attributedStringValue = Self.pathText(joining: appearance.pathComponents)
        }

        /// The path's components with Xcode's separator between each two: a space, SF Symbols'
        /// `chevron.compact.right` at the line's size and colour, and a space.
        private static func pathText(joining pathComponents: [String]) -> NSAttributedString {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Metrics.pathFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let pathText = NSMutableAttributedString()
            for (componentIndex, component) in pathComponents.enumerated() {
                if componentIndex > 0 {
                    pathText.append(NSAttributedString(string: " ", attributes: attributes))
                    pathText.append(chevron(attributes: attributes))
                    pathText.append(NSAttributedString(string: " ", attributes: attributes))
                }
                pathText.append(NSAttributedString(string: component, attributes: attributes))
            }
            return pathText
        }

        private static func chevron(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.pathFontSize, weight: .regular)
                .applying(.init(hierarchicalColor: .secondaryLabelColor))
            guard let image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return NSAttributedString(string: "›", attributes: attributes) }
            let attachment = NSTextAttachment()
            attachment.image = image
            let chevron = NSMutableAttributedString(attachment: attachment)
            chevron.addAttributes(attributes, range: NSRange(location: 0, length: chevron.length))
            return chevron
        }
    }
}

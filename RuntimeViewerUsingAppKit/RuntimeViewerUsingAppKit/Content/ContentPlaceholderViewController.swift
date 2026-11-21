import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// An editor pane with nothing open: the start page — Xcode 27.2's initial editor, an Open Quickly
/// field over the engine's recent objects (proposal `editor-start-page`) — or, while the window's
/// file is still being read, a spinner that says so.
final class ContentPlaceholderViewController: BaseViewController<ContentPlaceholderViewModel> {
    // MARK: - Start Page

    private let startPageView = NSView()

    private let searchField = OpenQuicklyField().then {
        $0.placeholderString = "Open Quickly"
    }

    private let recentItemsTitleLabel = Label("Recent Objects").then {
        $0.font = .systemFont(ofSize: Metrics.sectionTitleFontSize, weight: .medium)
        $0.textColor = .labelColor
    }

    private let (recentItemsScrollView, recentItemsTableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

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
            recentItemsScrollView
        }

        startPageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        readingStackView.snp.makeConstraints { make in
            make.center.equalTo(containerView)
        }

        searchField.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(Metrics.searchFieldTopInset)
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(Metrics.contentWidthFraction).priority(.high)
            make.width.lessThanOrEqualTo(Metrics.maximumContentWidth)
            make.leading.greaterThanOrEqualToSuperview().inset(Metrics.minimumHorizontalInset)
        }

        recentItemsTitleLabel.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(Metrics.sectionTopSpacing)
            make.leading.equalTo(searchField).inset(Metrics.sectionTitleLeadingInset)
            make.trailing.lessThanOrEqualTo(searchField)
        }

        recentItemsScrollView.snp.makeConstraints { make in
            make.top.equalTo(recentItemsTitleLabel.snp.bottom).offset(Metrics.listTopSpacing)
            make.leading.trailing.equalTo(searchField)
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
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ContentPlaceholderViewModel) {
        super.setupBindings(for: viewModel)

        let output = viewModel.transform(.init())

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

        output.recentItems.driveOnNext { [weak self] recentItems in
            guard let self else { return }
            recentItemsTitleLabel.isHidden = recentItems.isEmpty
        }
        .disposed(by: rx.disposeBag)

        output.recentItems
            .drive(recentItemsTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: ContentStartPageItemCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: ItemCellView.self)
                cellView.configure(with: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)
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
    /// The start page's measurements, after Xcode 27.2's initial editor.
    fileprivate enum Metrics {
        static let searchFieldTopInset: CGFloat = 42
        static let contentWidthFraction: CGFloat = 0.665
        static let maximumContentWidth: CGFloat = 800
        static let minimumHorizontalInset: CGFloat = 20
        static let sectionTopSpacing: CGFloat = 52
        static let sectionTitleLeadingInset: CGFloat = 4
        static let sectionTitleFontSize: CGFloat = 22
        static let listTopSpacing: CGFloat = 18
        static let rowHeight: CGFloat = 38
        static let rowLeadingInset: CGFloat = 26
        static let rowTrailingInset: CGFloat = 20
        static let iconToTextSpacing: CGFloat = 8
        static let titleFontSize: CGFloat = 13
        static let pathFontSize: CGFloat = 11
        static let pathIconSide: CGFloat = 11
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
    /// A row of the start page: the item's icon and name, and under them its path — the first
    /// component's icon, then the components joined with chevrons — over a hairline that starts
    /// under the text.
    fileprivate final class ItemCellView: TableCellView {
        private let iconView = ImageView()

        private let titleLabel = Label().then {
            $0.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 1
        }

        private let pathIconView = ImageView()

        private let pathLabel = Label().then {
            $0.font = .systemFont(ofSize: Metrics.pathFontSize, weight: .regular)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 1
        }

        private let separatorView = HorizontalSeparatorView()

        override func setup() {
            super.setup()

            let pathStackView = HStackView(spacing: 3) {
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
                make.leading.equalToSuperview().inset(Metrics.rowLeadingInset)
                make.centerY.equalToSuperview()
                make.size.equalTo(ContentStartPageItemCellViewModel.iconSize)
            }

            pathIconView.snp.makeConstraints { make in
                make.size.equalTo(Metrics.pathIconSide)
            }

            textStackView.snp.makeConstraints { make in
                make.leading.equalTo(iconView.snp.trailing).offset(Metrics.iconToTextSpacing)
                make.trailing.lessThanOrEqualToSuperview().inset(Metrics.rowTrailingInset)
                make.centerY.equalToSuperview()
            }

            separatorView.snp.makeConstraints { make in
                make.leading.equalTo(textStackView)
                make.trailing.equalToSuperview().inset(Metrics.rowTrailingInset)
                make.bottom.equalToSuperview()
            }
        }

        func configure(with cellViewModel: ContentStartPageItemCellViewModel) {
            let appearance = cellViewModel.appearance
            iconView.image = appearance.icon.image(size: ContentStartPageItemCellViewModel.iconSize)
            titleLabel.stringValue = appearance.title
            pathIconView.image = appearance.pathIcon?.image(size: Metrics.pathIconSide)
            pathIconView.isHidden = appearance.pathIcon == nil
            pathLabel.stringValue = appearance.pathComponents.joined(separator: " 〉 ")
        }
    }
}

import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCore

/// Popover host for the sidebar scope picker. Lets the user narrow the
/// sidebar list by `RuntimeObjectKind` (per-group tristate plus per-kind
/// checkboxes) and by `RuntimeObject.Properties` (per-property
/// Any/Only/Exclude). All edits land back on the view model's relay live —
/// dismissing the popover commits whatever is showing.
///
/// Inherits from `AppKitViewController` (plain `NSViewController`), NOT
/// `UXKitViewController`, so that `preferredContentSize` updates flow
/// through standard `NSViewController` KVO directly to `NSPopover`. The
/// previous UXKit-based version had to be presented through
/// `UXPopoverController`, which KVOed `preferredContentSize` on its own and
/// re-emitted intermediate values to `NSPopover.contentSize` whenever the
/// property was animated — producing the "popover collapses to zero before
/// growing" glitch during disclosure expansion.
final class SidebarRuntimeObjectScopeViewController: UXKitViewController<SidebarRuntimeObjectScopeViewModel<SidebarRuntimeObjectRoute>> {
    // MARK: - Header

    private let titleLabel = Label("Filter Scope")
    private let resetButton = NSButton()

    // MARK: - Kind section

    private let kindHeaderLabel = Label("Kind")
    private lazy var groupRows: [RuntimeObjectScope.KindGroup: KindGroupRow] = {
        var rows: [RuntimeObjectScope.KindGroup: KindGroupRow] = [:]
        for group in RuntimeObjectScope.KindGroup.allCases {
            rows[group] = KindGroupRow(group: group)
        }
        return rows
    }()

    // MARK: - Property section

    private let propertyHeaderLabel = Label("Properties")
    private let genericRow = PropertyRow(title: "Generic")
    private let specializedRow = PropertyRow(title: "Specialized")

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        
        configureHeader()
        configureKindSection()
        configurePropertySection()

        let kindStack = VStackView(distribution: .fill, alignment: .fill, spacing: 6) {
            kindHeaderLabel
            groupRows[.c]!
            groupRows[.objectiveC]!
            groupRows[.swift]!
        }

        let propertyStack = VStackView(distribution: .fill, alignment: .fill, spacing: 6) {
            propertyHeaderLabel
            genericRow
            specializedRow
        }

        let headerRow = HStackView(distribution: .fill, alignment: .fill, spacing: 8) {
            titleLabel
            NSView()
            resetButton
        }

        let contentStack = VStackView(distribution: .fill, alignment: .fill, spacing: 14) {
            headerRow
            NSBox().then { $0.boxType = .separator }
                .box
                .size(height: 1)
            kindStack
            NSBox().then { $0.boxType = .separator }
                .box
                .size(height: 1)
            propertyStack
        }

        view.hierarchy {
            contentStack
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        }

        // Constrain width so the row layouts (which depend on label
        // intrinsic widths) collapse to a stable popover size rather than
        // expanding to match each Swift kind row.
        contentStack.snp.makeConstraints { make in
            make.width.equalTo(300)
        }

        preferredContentSize = view.fittingSize
    }
    
    private func configureHeader() {
        titleLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
        }
        resetButton.do {
            $0.title = "Reset"
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.controlSize = .small
            $0.toolTip = "Clear all scope constraints"
        }
    }

    private func configureKindSection() {
        kindHeaderLabel.do {
            $0.font = .systemFont(ofSize: 11, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }
    }

    private func configurePropertySection() {
        propertyHeaderLabel.do {
            $0.font = .systemFont(ofSize: 11, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: SidebarRuntimeObjectScopeViewModel<SidebarRuntimeObjectRoute>) {
        super.setupBindings(for: viewModel)

        applyAvailability(
            kinds: viewModel.availableKinds,
            properties: viewModel.availableProperties
        )

        let rowEntries = groupRows.values
        let toggleKindStream = Observable.merge(rowEntries.map { $0.toggleKind })
        let toggleGroupStream = Observable.merge(rowEntries.map { $0.toggleGroup })
        let disclosureChangedStream = Observable.merge(rowEntries.map { $0.disclosureChanged })

        let input = SidebarRuntimeObjectScopeViewModel<SidebarRuntimeObjectRoute>.Input(
            toggleKind: toggleKindStream.asSignal(onErrorSignalWith: .empty()),
            toggleGroup: toggleGroupStream.asSignal(onErrorSignalWith: .empty()),
            setGeneric: genericRow.stateChanged.asSignal(onErrorSignalWith: .empty()),
            setSpecialized: specializedRow.stateChanged.asSignal(onErrorSignalWith: .empty()),
            reset: resetButton.rx.click.asSignal()
        )

        let output = viewModel.transform(input)

        output.draft.driveOnNextMainActor { [weak self] scope in
            guard let self else { return }
            apply(scope)
        }
        .disposed(by: rx.disposeBag)

        disclosureChangedStream
            .asSignal(onErrorSignalWith: .empty())
            .emitOnNextMainActor { [weak self] in
                guard let self else { return }
                // 1. Flip body state SYNCHRONOUSLY, OUTSIDE any animation
                //    context. Setting `bodyStack.isHidden = true` inside
                //    an `allowsImplicitAnimation = true` block makes
                //    AppKit treat it as an animator-proxy alpha fade and
                //    leaves NSStackView's `detachesHiddenViews` mechanism
                //    in the OLD arrangement until the animation completes
                //    — so `view.fittingSize` keeps returning the
                //    pre-collapse size and the popover never shrinks.
                //    Synchronous assignment lets NSStackView re-arrange
                //    immediately, so the layout pass below reads the
                //    correct natural size.
                for row in self.groupRows.values {
                    row.applyDisclosureState()
                }
                self.view.layoutSubtreeIfNeeded()
                let newSize = self.view.fittingSize

                // 2. Animate the popover resize. Plain NSPopover (now
                //    that the VC is a regular NSViewController) observes
                //    `preferredContentSize` via standard KVO and runs
                //    its own resize animation when the value changes
                //    inside an open CATransaction. `allowsImplicitAnimation`
                //    is fine here — the popover is the only animatable
                //    consumer left in this block.
                NSAnimationContext.runAnimationGroup { [self] context in
                    context.duration = KindGroupRow.disclosureAnimationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    self.preferredContentSize = newSize
                }
            }
            .disposed(by: rx.disposeBag)
    }

    /// One-shot at popover-open time: hide group rows whose intersection
    /// with `kinds` is empty, hide individual kind checkboxes for kinds
    /// that don't appear in the image, and hide property rows for bits
    /// nothing in the image carries.
    private func applyAvailability(
        kinds: Set<RuntimeObjectKind>,
        properties: RuntimeObject.Properties
    ) {
        for (group, row) in groupRows {
            let visibleKinds = Set(group.kinds).intersection(kinds)
            row.isHidden = visibleKinds.isEmpty
            row.applyVisibleKinds(visibleKinds)
        }
        genericRow.isHidden = !properties.contains(.isGeneric)
        specializedRow.isHidden = !properties.contains(.isSpecialized)
    }

    private func apply(_ scope: RuntimeObjectScope) {
        for (group, row) in groupRows {
            row.apply(scope: scope, group: group)
        }
        genericRow.apply(state: scope.generic)
        specializedRow.apply(state: scope.specialized)
        preferredContentSize = view.fittingSize
    }
}

// MARK: - Kind group row

extension SidebarRuntimeObjectScopeViewController {
    /// Header + collapsible body for one of the three coarse kind groups.
    /// The header carries a tristate checkbox; clicking the disclosure
    /// chevron expands the body where every individual kind has its own
    /// checkbox.
    ///
    /// Click events are forwarded as Observables (`toggleGroup`,
    /// `toggleKind`, `disclosureChanged`). The aggregation through internal
    /// `PublishRelay`s is necessary because the row owns multiple per-kind
    /// child buttons — the parent does not subscribe to each child
    /// directly, it consumes the row's merged stream. This is the
    /// "dynamically rebuilt child views" exception called out in CLAUDE.md.
    fileprivate final class KindGroupRow: NSView {
        var toggleGroup: Observable<RuntimeObjectScope.KindGroup> {
            toggleGroupRelay.asObservable()
        }

        var toggleKind: Observable<RuntimeObjectKind> {
            toggleKindRelay.asObservable()
        }

        var disclosureChanged: Observable<Void> {
            disclosureChangedRelay.asObservable()
        }

        private let toggleGroupRelay = PublishRelay<RuntimeObjectScope.KindGroup>()
        private let toggleKindRelay = PublishRelay<RuntimeObjectKind>()
        private let disclosureChangedRelay = PublishRelay<Void>()

        private let group: RuntimeObjectScope.KindGroup
        private let headerCheckbox = NSButton()
        private let disclosureButton = NSButton()
        private let titleLabel = Label()
        private let bodyStack = NSStackView()
        private var contentStackView: NSStackView?
        private var kindCheckboxes: [RuntimeObjectKind: NSButton] = [:]
        /// Kinds the parent VC has flagged as "actually present in the
        /// image." Hidden checkboxes still live in `kindCheckboxes` so the
        /// tristate header logic can ignore them. Empty until the VC calls
        /// `applyVisibleKinds(_:)` once at popover-open time; before that
        /// every kind is treated as visible (defensive default for unit
        /// tests / previews).
        private var visibleKinds: Set<RuntimeObjectKind>?

        init(group: RuntimeObjectScope.KindGroup) {
            self.group = group
            super.init(frame: .zero)

            configureSubviews()
            buildLayout()
            wireActions()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize {
            guard let contentStackView else { return super.intrinsicContentSize }
            return NSSize(width: NSView.noIntrinsicMetric, height: contentStackView.fittingSize.height)
        }

        private func configureSubviews() {
            titleLabel.do {
                $0.stringValue = group.title
                $0.font = .systemFont(ofSize: 12, weight: .medium)
                $0.textColor = .labelColor
            }

            headerCheckbox.do {
                $0.setButtonType(.switch)
                $0.title = ""
                $0.allowsMixedState = true
                $0.toolTip = "Toggle all \(group.title) kinds"
            }

            disclosureButton.do {
                $0.bezelStyle = .disclosure
                $0.setButtonType(.onOff)
                $0.title = ""
                $0.state = .off
            }

            bodyStack.do {
                $0.translatesAutoresizingMaskIntoConstraints = false
                $0.distribution = .fill
                $0.orientation = .vertical
                $0.alignment = .leading
                $0.spacing = 4
                $0.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 4, right: 0)
            }

            for kind in group.kinds {
                let checkbox = NSButton().then {
                    $0.setButtonType(.switch)
                    $0.title = kind.scopePopoverShortTitle
                    $0.translatesAutoresizingMaskIntoConstraints = false
                    $0.setContentHuggingPriority(.required, for: .vertical)
                    $0.setContentCompressionResistancePriority(.required, for: .vertical)
                }
                kindCheckboxes[kind] = checkbox
            }
        }

        private func buildLayout() {
            let headerRow = HStackView(distribution: .fill, alignment: .fill, spacing: 6) {
                disclosureButton
                headerCheckbox
                titleLabel
                NSView()
            }

            let contentStackView = VStackView(distribution: .fill, alignment: .fill, spacing: 2) {
                headerRow
                bodyStack
            }
            self.contentStackView = contentStackView

            addSubview(contentStackView)
            contentStackView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        private func wireActions() {
            // Header click → emit group identifier (model handles the
            // tristate semantics; the checkbox state is reconciled in
            // `apply(scope:group:)`).
            headerCheckbox.rx.click
                .map { [group] in group }
                .bind(to: toggleGroupRelay)
                .disposed(by: rx.disposeBag)

            // Per-kind clicks → emit the kind. Each child button has its
            // own rx subscription; RxAppKit's ActionProxy lets them coexist
            // on the same control if needed.
            for (kind, checkbox) in kindCheckboxes {
                checkbox.rx.click
                    .map { kind }
                    .bind(to: toggleKindRelay)
                    .disposed(by: rx.disposeBag)
            }

            // Forward disclosure clicks so the parent VC can drive the
            // animation. The row deliberately does NOT animate its own
            // body inside a separate `NSAnimationContext` because that can
            // run a frame ahead of the popover resize.
            disclosureButton.rx.click
                .bind(to: disclosureChangedRelay)
                .disposed(by: rx.disposeBag)

            // Initial state: collapsed.
            applyDisclosureState()
        }

        /// Sync `bodyStack`'s visibility with the disclosure button's
        /// current state. This is called synchronously before the parent
        /// view controller measures the target popover size.
        fileprivate func applyDisclosureState() {
            if disclosureButton.state == .on {
                rebuildBodyStackArrangedSubviews()
                bodyStack.isHidden = false
            } else {
                bodyStack.isHidden = true
                removeBodyStackArrangedSubviews()
            }
            invalidateLayoutSizing()
        }

        fileprivate static let disclosureAnimationDuration: TimeInterval = 0.2

        /// Hide every child checkbox whose kind isn't in `kinds`. Called
        /// once by the parent VC at popover-open time so the row only
        /// surfaces kinds the current image actually carries.
        func applyVisibleKinds(_ kinds: Set<RuntimeObjectKind>) {
            visibleKinds = kinds
            if disclosureButton.state == .on {
                rebuildBodyStackArrangedSubviews()
            }
            invalidateLayoutSizing()
        }

        func apply(scope: RuntimeObjectScope, group: RuntimeObjectScope.KindGroup) {
            let allKinds = Set(group.kinds)
            // Treat an empty `includedKinds` (no constraint) as fully-selected
            // so checkboxes start in the user-intuitive "everything is in" state.
            let effective: Set<RuntimeObjectKind>
            if scope.includedKinds.isEmpty {
                effective = allKinds
            } else {
                effective = scope.includedKinds.intersection(allKinds)
            }
            for (kind, checkbox) in kindCheckboxes {
                checkbox.state = effective.contains(kind) ? .on : .off
            }

            // Header tristate is computed over the visible kinds only so a
            // group that happens to contain an unavailable kind still
            // shows `.on` when every checkbox the user can see is ticked.
            let consideredKinds = visibleKinds ?? allKinds
            let effectiveVisible = effective.intersection(consideredKinds)
            if consideredKinds.isEmpty || effectiveVisible.isEmpty {
                headerCheckbox.state = .off
            } else if effectiveVisible == consideredKinds {
                headerCheckbox.state = .on
            } else {
                headerCheckbox.state = .mixed
            }
        }

        private func invalidateLayoutSizing() {
            bodyStack.invalidateIntrinsicContentSize()
            contentStackView?.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
            superview?.invalidateIntrinsicContentSize()
        }

        private func rebuildBodyStackArrangedSubviews() {
            removeBodyStackArrangedSubviews()

            let currentlyVisibleKinds = visibleKinds ?? Set(group.kinds)
            for kind in group.kinds where currentlyVisibleKinds.contains(kind) {
                guard let checkbox = kindCheckboxes[kind] else { continue }
                checkbox.isHidden = false
                bodyStack.addArrangedSubview(checkbox)
            }
        }

        private func removeBodyStackArrangedSubviews() {
            for arrangedSubview in bodyStack.arrangedSubviews {
                bodyStack.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }
        }
    }
}

// MARK: - Property row

extension SidebarRuntimeObjectScopeViewController {
    /// One property row: title on the left, Any / Only / Exclude segmented
    /// control on the right. The control width matches across rows so the
    /// rightmost edges line up visually.
    fileprivate final class PropertyRow: NSView {
        var stateChanged: Observable<RuntimeObjectScope.PropertyState> {
            stateChangedRelay.asObservable()
        }

        private let stateChangedRelay = PublishRelay<RuntimeObjectScope.PropertyState>()

        private let titleLabel = Label()
        private let segmented = NSSegmentedControl()
        private var rowStackView: NSStackView?

        init(title: String) {
            super.init(frame: .zero)

            titleLabel.do {
                $0.stringValue = title
                $0.font = .systemFont(ofSize: 12)
                $0.textColor = .labelColor
            }

            segmented.do {
                $0.segmentStyle = .rounded
                $0.segmentCount = 3
                $0.setLabel("Any", forSegment: 0)
                $0.setLabel("Only", forSegment: 1)
                $0.setLabel("Exclude", forSegment: 2)
                $0.selectedSegment = 0
                $0.trackingMode = .selectOne
                $0.controlSize = .small
                $0.font = .systemFont(ofSize: 11)
            }

            let rowStackView = HStackView(distribution: .fill, alignment: .fill, spacing: 8) {
                titleLabel
                NSView()
                segmented
            }
            self.rowStackView = rowStackView

            addSubview(rowStackView)
            rowStackView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            // User clicks a segment → look up the new selection and emit
            // the mapped state. `rx.click` fires after the control flips
            // `selectedSegment`, so reading it inside the bind closure
            // returns the post-click value.
            segmented.rx.click
                .compactMap { [weak segmented] _ -> RuntimeObjectScope.PropertyState? in
                    guard let segmented else { return nil }
                    switch segmented.selectedSegment {
                    case 1: return .only
                    case 2: return .exclude
                    default: return .any
                    }
                }
                .bind(to: stateChangedRelay)
                .disposed(by: rx.disposeBag)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize {
            guard let rowStackView else { return super.intrinsicContentSize }
            return NSSize(width: NSView.noIntrinsicMetric, height: rowStackView.fittingSize.height)
        }

        func apply(state: RuntimeObjectScope.PropertyState) {
            switch state {
            case .any: segmented.selectedSegment = 0
            case .only: segmented.selectedSegment = 1
            case .exclude: segmented.selectedSegment = 2
            }
        }
    }
}

// MARK: - Kind labels

extension RuntimeObjectKind {
    /// Short label used inside the scope popover; the group title is
    /// rendered separately as the section header so this strips the
    /// language prefix (e.g. "Swift Class" → "Class") to keep rows compact.
    fileprivate var scopePopoverShortTitle: String {
        switch self {
        case .c(.struct): return "Struct"
        case .c(.union): return "Union"
        case .objc(.type(.class)): return "Class"
        case .objc(.type(.protocol)): return "Protocol"
        case .objc(.category(.class)): return "Class Category"
        case .objc(.category(.protocol)): return "Protocol Category"
        case .swift(.type(let kind)): return swiftKindBase(kind)
        case .swift(.extension(let kind)): return "\(swiftKindBase(kind)) Extension"
        case .swift(.conformance(let kind)): return "\(swiftKindBase(kind)) Conformance"
        }
    }
}

private func swiftKindBase(_ kind: RuntimeObjectKind.Swift.Kind) -> String {
    switch kind {
    case .enum: return "Enum"
    case .struct: return "Struct"
    case .class: return "Class"
    case .protocol: return "Protocol"
    case .typeAlias: return "TypeAlias"
    }
}

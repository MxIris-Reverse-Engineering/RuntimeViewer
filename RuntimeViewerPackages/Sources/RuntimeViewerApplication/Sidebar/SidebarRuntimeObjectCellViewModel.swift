#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class SidebarRuntimeObjectCellViewModel: NSObject, OutlineNodeType, FilterableItem, @unchecked Sendable {
    /// Stable identity used by `Differentiable` and for in-place reuse during
    /// `rebuildChildren()`. Crucially does NOT depend on `RuntimeObject.children`,
    /// so a parent whose children change (e.g. via specialization) still
    /// matches its previous instance.
    ///
    /// `parentFingerprint` folds the entire ancestry chain into a single
    /// `Int`, which is what lets two cells with the same `(imagePath, name,
    /// kind)` but different sidebar positions stay distinct — e.g. the
    /// `Phase.Value<Event>` produced by directly specializing the inner
    /// generic vs. the `Phase<Event>.Value` derived when the outer generic
    /// gets specialized.
    public struct StableID: Hashable {
        public let imagePath: String
        public let name: String
        public let kind: RuntimeObjectKind
        public let parentFingerprint: Int
    }

    /// Mutable so the sidebar can splice in a new specialized child via
    /// `parentVM.runtimeObject = parent.withAppendedChild(child)` and have
    /// the children tree rebuild itself (reusing surviving child instances)
    /// and the displayed name/icons refresh, without rebuilding the parent
    /// viewmodel itself.
    public var runtimeObject: RuntimeObject {
        didSet {
            guard oldValue != runtimeObject else { return }
            rebuildChildren()
            refreshAppearance()
        }
    }

    public let forOpenQuickly: Bool

    /// Sidebar-tree parent. Weak to avoid retain cycles since the parent
    /// strongly holds its children via `_children`. Only the cell's own
    /// position in the sidebar uses this — `RuntimeObject` itself stays
    /// position-agnostic.
    public private(set) weak var parent: SidebarRuntimeObjectCellViewModel?

    /// Recursive identity hash folding `parent.fingerprint` into the cell's
    /// own `(imagePath, name, kind)`. Not cached: `stableID` reads it on
    /// demand so a late-binding `parent` change (or `parent` deallocation)
    /// just shows up next access. `runtimeObject.children` is intentionally
    /// excluded — splicing a child must not flip the parent's fingerprint.
    public var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(parent?.fingerprint ?? 0)
        hasher.combine(runtimeObject.imagePath)
        hasher.combine(runtimeObject.name)
        hasher.combine(runtimeObject.kind)
        return hasher.finalize()
    }

    public var stableID: StableID {
        StableID(
            imagePath: runtimeObject.imagePath,
            name: runtimeObject.name,
            kind: runtimeObject.kind,
            parentFingerprint: parent?.fingerprint ?? 0
        )
    }

    public var children: [SidebarRuntimeObjectCellViewModel] {
        get { _filteredChildren }
        set {
            _children = newValue
            _filteredChildren = newValue
            invalidateNamesCacheUpwards()
        }
    }

    public var isLeaf: Bool { children.isEmpty }

    private var _filteredChildren: [SidebarRuntimeObjectCellViewModel] = []

    private var _children: [SidebarRuntimeObjectCellViewModel] = []

    /// The unfiltered child list. The filter pipeline snapshots and
    /// re-applies against this array so the active filter never hides
    /// nodes from its own recomputation.
    var unfilteredChildren: [SidebarRuntimeObjectCellViewModel] { _children }

    /// Cached subtree haystack. Invalidated (upwards through the ancestor
    /// chain, since every ancestor's haystack embeds this subtree's names)
    /// whenever `_children` changes — the only mutation points are
    /// `rebuildChildren()` and the `children` setter, both main-actor.
    private var cachedCurrentAndChildrenNames: String?

    /// Filter haystack: this node's display name plus every descendant's,
    /// so a parent whose match lives in a descendant still surfaces.
    public var currentAndChildrenNames: String {
        if let cachedCurrentAndChildrenNames {
            return cachedCurrentAndChildrenNames
        }
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        let computedNames: String
        if childrenNames.isEmpty {
            computedNames = runtimeObject.displayName
        } else {
            computedNames = "\(runtimeObject.displayName) \(childrenNames)"
        }
        cachedCurrentAndChildrenNames = computedNames
        return computedNames
    }

    private func invalidateNamesCacheUpwards() {
        var currentCell: SidebarRuntimeObjectCellViewModel? = self
        while let cell = currentCell {
            cell.cachedCurrentAndChildrenNames = nil
            currentCell = cell.parent
        }
    }

    /// Pure-value replica of `currentAndChildrenNames`, computed straight
    /// from a `RuntimeObject` tree so callers can match against the
    /// haystack without materializing a cell view model first (Open
    /// Quickly matches all rows this way, then materializes cells only
    /// for hits).
    ///
    /// What `composedTitle()` depends on is the *prefix*: both this and
    /// `currentAndChildrenNames` put the node's own `displayName` first, so
    /// a fuzzy range below `displayName.count` addresses the same
    /// characters in the title as it does in the haystack it was scored
    /// against. Byte-for-byte parity between the two builders is no longer
    /// load-bearing — nothing crosses a range from one to the other — but
    /// both still sort children by `displayName` and join with single
    /// spaces, and `OpenQuicklyLazyConstructionTests` keeps them honest so
    /// the sidebar and Open Quickly rank identical trees identically.
    static func haystack(for runtimeObject: RuntimeObject) -> String {
        let sortedChildren = runtimeObject.children.sorted { leftChild, rightChild in
            leftChild.displayName < rightChild.displayName
        }
        let childrenNames = sortedChildren.map { haystack(for: $0) }.joined(separator: " ")
        if childrenNames.isEmpty {
            return runtimeObject.displayName
        }
        return "\(runtimeObject.displayName) \(childrenNames)"
    }

    private var filterContextStorage = FilterContext()

    /// The active text-filter context. Setting a *different* context
    /// re-derives `_filteredChildren` (which cascades into descendants via
    /// `FilterEngine.filter`); setting an equal context is free. The filter
    /// pipeline writes the storage directly through
    /// `applyFilterOutcome(...)` because it delivers the cascade's results
    /// itself.
    var filterContext: FilterContext {
        get { filterContextStorage }
        set {
            guard filterContextStorage != newValue else { return }
            filterContextStorage = newValue
            applyLocalFilter()
        }
    }

    /// Scope filter applied to `_children` before the text filter runs.
    /// Plain storage: tree-wide propagation is owned by the filter
    /// pipeline's apply step (`applyFilterOutcome`), which visits every
    /// cell anyway; this stored copy only feeds `applyLocalFilter()` on
    /// the splice path.
    var scope: RuntimeObjectScope = .init()

    /// Re-derives `_filteredChildren` from the stored scope + filter
    /// context. Only invoked for cell-local mutations (children rebuilt
    /// after a specialization splice); bulk filtering goes through the
    /// pipeline's `applyFilterOutcome` instead.
    private func applyLocalFilter() {
        let scopeFiltered: [SidebarRuntimeObjectCellViewModel]
        if scope.isActive {
            scopeFiltered = _children.filter { $0.matchesScopeRecursively(scope) }
        } else {
            scopeFiltered = _children
        }
        _filteredChildren = FilterEngine.filter(context: filterContextStorage, items: scopeFiltered)
    }

    /// Returns `true` if this cell or any of its descendants pass `scope`.
    /// Walks the cell-viewmodel tree (`_children`) rather than the value-
    /// type runtime-object tree so it always sees splices applied by
    /// `appendRuntimeObjectChildPreservingCurrentDescendants(_:)` even
    /// when the ancestor's stored `runtimeObject` is stale.
    func matchesScopeRecursively(_ scope: RuntimeObjectScope) -> Bool {
        if scope.passes(runtimeObject) { return true }
        for child in _children {
            if child.matchesScopeRecursively(scope) { return true }
        }
        return false
    }

    /// Single entry point for the filter pipeline's main-actor apply step:
    /// synchronizes the stored context/scope WITHOUT re-triggering the
    /// local cascade (the pipeline already computed every level), installs
    /// the pre-ordered filtered children, and updates the highlight.
    func applyFilterOutcome(
        context: FilterContext,
        scope: RuntimeObjectScope,
        result: FuzzyFilterResult?,
        filteredChildren: [SidebarRuntimeObjectCellViewModel]
    ) {
        filterContextStorage = context
        self.scope = scope
        _filteredChildren = filteredChildren
        filterResult = result
    }

    var filterResult: FuzzyFilterResult? {
        didSet {
            // nil -> nil is the overwhelmingly common per-keystroke case
            // (rows that neither had nor gained a highlight); skipping it
            // is what keeps a filter pass from rebuilding every row's
            // attributed title. See SidebarFilterPerformanceBaselineTests.
            if oldValue == nil, filterResult == nil { return }
            rebuildTitleForFilterResult()
        }
    }

    /// Replaces only the title within the current appearance. The icons keep
    /// their existing references, so the `publishAppearance` equality check
    /// reduces to comparing the two attributed titles.
    private func rebuildTitleForFilterResult() {
        var rebuiltAppearance = appearance
        rebuiltAppearance.title = composedTitle()
        publishAppearance(rebuiltAppearance)
    }

    /// The display title under the current `filterResult`: the fuzzy-highlight
    /// rendition when a result is active, the plain default title otherwise.
    private func composedTitle() -> NSAttributedString {
        guard let filterResult else {
            return defaultAttributedTitle()
        }

        let title = NSMutableAttributedString {
            AText(runtimeObject.displayName)
                .font(.systemFont(ofSize: fontSize))
                .foregroundColor(forOpenQuickly ? .secondaryLabelColor : .tertiaryLabelColor)
                .alignment(.left)
                .lineBreakeMode(.byTruncatingTail)
        }

        // This row's own name is the prefix of its subtree haystack by
        // construction — `currentAndChildrenNames` builds
        // "displayName child1 child2 …" and `haystack(for:)` matches it
        // byte for byte. Searching the haystack for the name rediscovered
        // offset 0 by scanning the entire subtree string, on every row of
        // every keystroke; `ranges(of:)` collects *all* occurrences, so it
        // could not even stop at the first hit.
        //
        // Offsets stay in Characters, matching `integerRange(from:)`
        // (`distance(from:to:)`), so the ranges compared below are
        // unchanged.
        let currentNSRange = NSRange(location: 0, length: runtimeObject.displayName.count)

        for resultNSRange in filterResult.ranges {
            guard resultNSRange.location >= currentNSRange.location, NSMaxRange(resultNSRange) <= NSMaxRange(currentNSRange) else { continue }
            title.addAttributes([
                .foregroundColor: NSUIColor.labelColor,
                .font: NSUIFont.systemFont(ofSize: fontSize, weight: .semibold),
            ], range: resultNSRange)
        }
        return title
    }

    var filterableString: String {
        currentAndChildrenNames
    }

    private static let normalFontSize: CGFloat = 13

    private static let openQuicklyFontSize: CGFloat = 16

    private var fontSize: CGFloat {
        forOpenQuickly ? SidebarRuntimeObjectCellViewModel.openQuicklyFontSize : SidebarRuntimeObjectCellViewModel.normalFontSize
    }

    /// All visual state in one stream: one subject + lock per row instead of
    /// five, and every refresh publishes atomically (proposal 0005).
    @Observed
    public private(set) var appearance = RuntimeObjectCellAppearance()

    /// Whether `$appearance` has been materialized. `@Observed` creates its
    /// relay on first `$appearance` access, so every bulk path over the tree
    /// — filter apply, scope filter, type-select — must leave this `false`;
    /// only a cell view binding the row should flip it. Guarded by
    /// `SidebarFilterRelayMaterializationTests`.
    package var hasMaterializedAppearanceRelay: Bool {
        _appearance.hasMaterializedRelay
    }

    @NSAttributedStringBuilder
    private func defaultAttributedTitle() -> NSAttributedString {
        AText(runtimeObject.displayName)
            .font(.systemFont(ofSize: fontSize))
            .foregroundColor(.labelColor)
            .alignment(.left)
            .lineBreakeMode(.byTruncatingTail)
    }

    public init(runtimeObject: RuntimeObject, forOpenQuickly: Bool, parent: SidebarRuntimeObjectCellViewModel? = nil) {
        self.runtimeObject = runtimeObject
        self.forOpenQuickly = forOpenQuickly
        super.init()
        self.parent = parent
        rebuildChildren()
        refreshAppearance()
    }

    /// Re-derive `_children` from `runtimeObject.children`, reusing existing
    /// child viewmodel instances whose `StableID` matches so downstream
    /// `Differentiable` consumers see stable identities and outlineView
    /// state (selection/expansion) is preserved.
    private func rebuildChildren() {
        let parentFingerprint = fingerprint
        let recycledChildrenByStableID = Dictionary(
            _children.map { ($0.stableID, $0) },
            uniquingKeysWith: { firstViewModel, _ in firstViewModel }
        )
        let rebuiltChildren = runtimeObject.children.map { childRuntimeObject -> SidebarRuntimeObjectCellViewModel in
            let childStableID = StableID(
                imagePath: childRuntimeObject.imagePath,
                name: childRuntimeObject.name,
                kind: childRuntimeObject.kind,
                parentFingerprint: parentFingerprint
            )
            if let recycledChild = recycledChildrenByStableID[childStableID] {
                recycledChild.runtimeObject = childRuntimeObject // recurses via didSet
                return recycledChild
            }
            return Self(runtimeObject: childRuntimeObject, forOpenQuickly: forOpenQuickly, parent: self)
        }
        .sorted { leftChild, rightChild in
            leftChild.runtimeObject.displayName < rightChild.runtimeObject.displayName
        }
        _children = rebuiltChildren
        invalidateNamesCacheUpwards()
        applyLocalFilter()
    }

    /// Returns a RuntimeObject tree that reflects the current child viewmodels,
    /// including children that were spliced into descendants after this cell's
    /// original RuntimeObject was created.
    func materializedRuntimeObject() -> RuntimeObject {
        RuntimeObject(
            name: runtimeObject.name,
            displayName: runtimeObject.displayName,
            kind: runtimeObject.kind,
            secondaryKind: runtimeObject.secondaryKind,
            imagePath: runtimeObject.imagePath,
            children: _children.map { $0.materializedRuntimeObject() },
            properties: runtimeObject.properties
        )
    }

    @discardableResult
    func appendRuntimeObjectChildPreservingCurrentDescendants(_ child: RuntimeObject) -> Bool {
        let currentRuntimeObject = materializedRuntimeObject()
        guard !currentRuntimeObject.children.contains(where: { $0.key == child.key }) else {
            return false
        }
        runtimeObject = currentRuntimeObject.withAppendedChild(child)
        return true
    }

    /// Recompute icons and the highlighted name. Called whenever
    /// `runtimeObject` changes (e.g. a new specialized child arrives,
    /// flipping the parent's `properties` bookkeeping). Composes the full
    /// appearance and publishes it as one event.
    private func refreshAppearance() {
        let iconSize = forOpenQuickly ? 24 : RuntimeObjectIcon.defaultIconSize
        var refreshedAppearance = RuntimeObjectCellAppearance(
            primaryIcon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize),
            secondaryIcon: runtimeObject.secondaryKind.map { RuntimeObjectIcon.icon(for: $0, size: iconSize) },
            title: composedTitle()
        )

        if runtimeObject.properties.contains(.isGeneric) {
            refreshedAppearance.tertiaryIcon = RuntimeObjectIcon.iconForGeneric(size: iconSize)
        }

        if runtimeObject.properties.contains(.isSpecialized) {
            refreshedAppearance.tertiaryIcon = RuntimeObjectIcon.iconForSpecialized(size: iconSize)
        }

        publishAppearance(refreshedAppearance)
    }

    /// Equal-value updates are dropped so a refresh that changes nothing (a
    /// splice that leaves this row's display state untouched, or a filter
    /// pass re-delivering the same highlight) emits no event. Icons come from
    /// `RuntimeObjectIcon`'s cache, so unchanged icons are pointer-equal and
    /// the comparison cost concentrates on the attributed title.
    private func publishAppearance(_ newAppearance: RuntimeObjectCellAppearance) {
        guard newAppearance != appearance else { return }
        appearance = newAppearance
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SidebarRuntimeObjectCellViewModel: Differentiable {
    public var differenceIdentifier: StableID { stableID }
    public func isContentEqual(to source: SidebarRuntimeObjectCellViewModel) -> Bool {
        runtimeObject == source.runtimeObject
    }
}

extension SidebarRuntimeObjectCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif

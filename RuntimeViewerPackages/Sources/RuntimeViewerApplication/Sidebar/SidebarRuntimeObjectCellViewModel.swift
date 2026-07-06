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
        }
    }

    public var isLeaf: Bool { children.isEmpty }

    private var _filteredChildren: [SidebarRuntimeObjectCellViewModel] = []

    private var _children: [SidebarRuntimeObjectCellViewModel] = []

    /// Computed (not cached) so it always reflects the current subtree. Used
    /// only as a filter haystack; updates are infrequent (debounced search)
    /// so the recomputation cost is acceptable in exchange for eliminating
    /// the lazy-cache invalidation problem when children change.
    public var currentAndChildrenNames: String {
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        if childrenNames.isEmpty {
            return runtimeObject.displayName
        } else {
            return "\(runtimeObject.displayName) \(childrenNames)"
        }
    }

    @Dependency(\.appDefaults)
    private var appDefaults

    var isCaseInsensitive: Bool = false

    var filter: String = "" {
        didSet { applyFilter() }
    }

    /// Scope filter applied to `_children` before the text filter runs.
    /// Pushed down from `SidebarRuntimeObjectViewModel` whenever the user
    /// edits the scope popover. The scope itself does not cascade through
    /// this setter — callers responsible for tree-wide propagation use
    /// `applyScopeRecursively(_:)` so every descendant ends up with the
    /// same value before any parent's `_filteredChildren` is read.
    var scope: RuntimeObjectScope = .init() {
        didSet {
            guard oldValue != scope else { return }
            applyFilter()
        }
    }

    private func applyFilter() {
        let scopeFiltered: [SidebarRuntimeObjectCellViewModel]
        if scope.isActive {
            scopeFiltered = _children.filter { $0.matchesScopeRecursively(scope) }
        } else {
            scopeFiltered = _children
        }
        _filteredChildren = FilterEngine.filter(filter, items: scopeFiltered, mode: appDefaults.filterMode, isCaseInsensitive: isCaseInsensitive)
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

    /// Push `newScope` into this cell and every descendant depth-first.
    /// Each cell's own `_filteredChildren` rebuild happens via the
    /// `scope` didSet, so after this call returns the entire subtree
    /// reflects the new scope consistently.
    func applyScopeRecursively(_ newScope: RuntimeObjectScope) {
        for child in _children {
            child.applyScopeRecursively(newScope)
        }
        scope = newScope
    }

    var filterResult: FuzzyFilterResult? {
        didSet {
            if let filterResult {
                let title = NSMutableAttributedString {
                    AText(runtimeObject.displayName)
                        .font(.systemFont(ofSize: fontSize))
                        .foregroundColor(forOpenQuickly ? .secondaryLabelColor : .tertiaryLabelColor)
                        .alignment(.left)
                        .lineBreakeMode(.byTruncatingTail)
                }

                guard let range = currentAndChildrenNames.ranges(of: runtimeObject.displayName).first else {
                    self.title = title
                    return
                }

                let currentNSRange = NSRange(currentAndChildrenNames.integerRange(from: range))

                for resultNSRange in filterResult.ranges {
                    guard resultNSRange.location >= currentNSRange.location, NSMaxRange(resultNSRange) <= NSMaxRange(currentNSRange) else { continue }
                    title.addAttributes([
                        .foregroundColor: NSUIColor.labelColor,
                        .font: NSUIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    ], range: resultNSRange)
                }
                self.title = title
            } else {
                title = defaultAttributedTitle()
            }
        }
    }

    var filterableString: String {
        currentAndChildrenNames
    }

    private static let normalFontSize: CGFloat = 13

    private static let openQuicklyFontSize: CGFloat = 16

    private var fontSize: CGFloat {
        forOpenQuickly ? SidebarRuntimeObjectCellViewModel.openQuicklyFontSize : SidebarRuntimeObjectCellViewModel.normalFontSize
    }

    @Observed
    public private(set) var primaryIcon: NSUIImage = .init()

    @Observed
    public private(set) var secondaryIcon: NSUIImage?

    @Observed
    public private(set) var tertiaryIcon: NSUIImage?

    @Observed
    public private(set) var title: NSAttributedString = .init()

    @Observed
    public private(set) var subtitle: NSAttributedString?

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
        applyFilter()
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
    /// flipping the parent's `properties` bookkeeping).
    private func refreshAppearance() {
        let iconSize = forOpenQuickly ? 24 : RuntimeObjectIcon.defaultIconSize
        primaryIcon = RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize)
        secondaryIcon = runtimeObject.secondaryKind.map { RuntimeObjectIcon.icon(for: $0, size: iconSize) }

        if runtimeObject.properties.contains(.isGeneric) {
            tertiaryIcon = RuntimeObjectIcon.iconForGeneric(size: iconSize)
        }

        if runtimeObject.properties.contains(.isSpecialized) {
            tertiaryIcon = RuntimeObjectIcon.iconForSpecialized(size: iconSize)
        }

        if let filterResult {
            // Trigger didSet to reapply highlight ranges over the new displayName.
            self.filterResult = filterResult
        } else {
            title = defaultAttributedTitle()
        }
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
    public var primaryIconDriver: Driver<NSUIImage> { $primaryIcon.asDriver() }
    public var secondaryIconDriver: Driver<NSUIImage?> { $secondaryIcon.asDriver() }
    public var tertiaryIconDriver: Driver<NSUIImage?> { $tertiaryIcon.asDriver() }
    public var titleDriver: Driver<NSAttributedString> { $title.asDriver() }
}

#endif

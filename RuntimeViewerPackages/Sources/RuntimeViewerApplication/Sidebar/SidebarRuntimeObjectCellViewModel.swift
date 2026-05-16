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
    public struct StableID: Hashable {
        public let imagePath: String
        public let name: String
        public let kind: RuntimeObjectKind
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

    public var stableID: StableID {
        StableID(imagePath: runtimeObject.imagePath, name: runtimeObject.name, kind: runtimeObject.kind)
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

    private func applyFilter() {
        _filteredChildren = FilterEngine.filter(filter, items: _children, mode: appDefaults.filterMode, isCaseInsensitive: isCaseInsensitive)
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

    public init(runtimeObject: RuntimeObject, forOpenQuickly: Bool) {
        self.runtimeObject = runtimeObject
        self.forOpenQuickly = forOpenQuickly
        super.init()
        rebuildChildren()
        refreshAppearance()
    }

    /// Re-derive `_children` from `runtimeObject.children`, reusing existing
    /// child viewmodel instances whose `StableID` matches so downstream
    /// `Differentiable` consumers see stable identities and outlineView
    /// state (selection/expansion) is preserved.
    private func rebuildChildren() {
        let recycledChildrenByStableID = Dictionary(
            _children.map { ($0.stableID, $0) },
            uniquingKeysWith: { firstViewModel, _ in firstViewModel }
        )
        let rebuiltChildren = runtimeObject.children.map { childRuntimeObject -> SidebarRuntimeObjectCellViewModel in
            let childStableID = StableID(
                imagePath: childRuntimeObject.imagePath,
                name: childRuntimeObject.name,
                kind: childRuntimeObject.kind
            )
            if let recycledChild = recycledChildrenByStableID[childStableID] {
                recycledChild.runtimeObject = childRuntimeObject // recurses via didSet
                return recycledChild
            }
            return Self(runtimeObject: childRuntimeObject, forOpenQuickly: forOpenQuickly)
        }
        .sorted { leftChild, rightChild in
            leftChild.runtimeObject.displayName < rightChild.runtimeObject.displayName
        }
        _children = rebuiltChildren
        applyFilter()
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

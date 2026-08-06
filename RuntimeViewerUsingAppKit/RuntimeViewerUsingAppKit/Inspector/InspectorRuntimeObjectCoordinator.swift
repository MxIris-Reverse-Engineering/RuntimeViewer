import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias InspectorRuntimeObjectTransition = Transition<Void, InspectorRuntimeObjectTabViewController>

final class InspectorRuntimeObjectCoordinator: ViewCoordinator<InspectorRuntimeObjectRoute, InspectorRuntimeObjectTransition> {
    /// Identifies an inspector tab independently of its display order, so
    /// the user's "last selected tab" can be restored across RuntimeObject
    /// switches even when the new object's `TabConfiguration` produces a
    /// different ordering or omits some tabs entirely.
    enum TabKind {
        case classHierarchy
        case relationships
        case specialization
    }

    protocol Delegate: AnyObject {
        func inspectorRuntimeObjectCoordinator(
            _ coordinator: InspectorRuntimeObjectCoordinator,
            didRequestSpecializationSheetFor object: RuntimeObject
        )
        func inspectorRuntimeObjectCoordinator(
            _ coordinator: InspectorRuntimeObjectCoordinator,
            didSelectTab tabKind: TabKind
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    /// Object currently being inspected. `nil` before the first call to
    /// `update(for:preferredTabKind:)`; never re-set to `nil` afterwards
    /// because `InspectorCoordinator` swaps the entire scene to the
    /// placeholder view controller instead of clearing this coordinator.
    private(set) var runtimeObject: RuntimeObject?

    private var tabConfiguration: TabConfiguration = .empty

    private var preferredTabKind: TabKind?

    // MARK: - Reused tab view controllers and ViewModels
    //
    // Each tab kind has a single, lazily-initialized view controller *and* a
    // single ViewModel, both reused across every
    // `update(for:preferredTabKind:)` call. `setupBindings(for:)` therefore
    // runs exactly once per tab; afterwards a new `RuntimeObject` is pushed
    // into the existing ViewModel through `update(for:)`.
    //
    // Rebinding per object was the direct cause of the Inspector flashing on
    // every selection change: `setupBindings(for:)` resets `rx.disposeBag`,
    // which tears down the `tableView.rx.items` binding and installs a fresh
    // RxAppKit adapter whose item list starts out empty — so the list blanked
    // on the spot and only refilled once the (cross-image, and therefore
    // slow) query came back. Keeping the binding alive means the only thing
    // that ever reaches the view is a state change from the ViewModel, which
    // carries its own loading placeholder.

    private lazy var classViewController = InspectorClassViewController()
    private lazy var relationshipsViewController = InspectorRelationshipsViewController()
    private lazy var specializationViewController = InspectorSwiftSpecializationViewController()

    private var classViewModel: InspectorClassViewModel?
    private var relationshipsViewModel: InspectorRelationshipsViewModel?
    private var specializationViewModel: InspectorSwiftSpecializationViewModel?

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(), initialRoute: nil)
        rootViewController.onUserSelectIndex = { [weak self] index in
            guard let self else { return }
            guard let tabKind = tabConfiguration.tabKind(at: index) else { return }
            delegate?.inspectorRuntimeObjectCoordinator(self, didSelectTab: tabKind)
        }
    }

    /// Apply a new `RuntimeObject` to the existing tab view controllers.
    ///
    /// Hot path (same `TabConfiguration` as last time): only push the object
    /// into the per-tab ViewModels; the `NSTabView` is not touched.
    ///
    /// Cold path (configuration changed — different `RuntimeObject.kind`,
    /// generic-ness, etc.): additionally trigger a `Transition.set` on
    /// `TabViewController`, which reconciles the tab items in place — tabs
    /// that survive keep their view, so only the appearing/disappearing ones
    /// actually change.
    func update(for runtimeObject: RuntimeObject, preferredTabKind: TabKind?) {
        let newConfiguration = TabConfiguration.compute(for: runtimeObject)
        let configurationChanged = newConfiguration != tabConfiguration

        self.runtimeObject = runtimeObject
        self.tabConfiguration = newConfiguration
        self.preferredTabKind = preferredTabKind

        updateTabViewControllers(for: runtimeObject)

        if configurationChanged {
            contextTrigger(.initial)
        } else if let preferredIndex = preferredTabKind.flatMap({ newConfiguration.index(for: $0) }),
                  rootViewController.isViewLoaded,
                  rootViewController.selectedTabViewItemIndex != preferredIndex {
            rootViewController.selectedTabViewItemIndex = preferredIndex
        }
    }

    override func prepareTransition(for route: InspectorRuntimeObjectRoute) -> InspectorRuntimeObjectTransition {
        switch route {
        case .initial:
            let items = makeTabViewItems()
            let initialIndex = preferredTabKind.flatMap { tabConfiguration.index(for: $0) } ?? 0
            return .set(items, initialIndex: initialIndex)
        case .classHierarchy:
            guard let index = tabConfiguration.classHierarchyIndex else { return .none() }
            return .select(index: index)
        case .relationships:
            guard let index = tabConfiguration.relationshipsIndex else { return .none() }
            return .select(index: index)
        case .specialization:
            guard let index = tabConfiguration.specializationIndex else { return .none() }
            return .select(index: index)
        case .requestSpecializationSheet(let object):
            delegate?.inspectorRuntimeObjectCoordinator(self, didRequestSpecializationSheetFor: object)
            return .none()
        }
    }

    /// Point every tab the new configuration needs at `runtimeObject`. Tabs
    /// the configuration leaves out are skipped: they are off screen, so
    /// refreshing them would only cost a query nobody is waiting for. They
    /// catch up the next time they are needed, because `update(for:)` is
    /// driven by the object and not by a subscription.
    private func updateTabViewControllers(for runtimeObject: RuntimeObject) {
        if tabConfiguration.needsClassHierarchy {
            if let classViewModel {
                classViewModel.update(for: runtimeObject)
            } else {
                let viewModel = InspectorClassViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
                classViewController.setupBindings(for: viewModel)
                classViewModel = viewModel
            }
        }
        if tabConfiguration.needsRelationships {
            if let relationshipsViewModel {
                relationshipsViewModel.update(for: runtimeObject)
            } else {
                let viewModel = InspectorRelationshipsViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
                relationshipsViewController.setupBindings(for: viewModel)
                relationshipsViewModel = viewModel
            }
        }
        if tabConfiguration.needsSpecialization {
            if let specializationViewModel {
                specializationViewModel.update(for: runtimeObject)
            } else {
                let viewModel = InspectorSwiftSpecializationViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
                specializationViewController.setupBindings(for: viewModel)
                specializationViewModel = viewModel
            }
        }
    }

    private func makeTabViewItems() -> [TabViewItem] {
        guard runtimeObject != nil else { return [] }
        var tabViewItems: [TabViewItem] = []
        if tabConfiguration.needsClassHierarchy {
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .squareStack3dUp),
                    selectedSymbol: .init(systemName: .squareStack3dUpFill),
                    viewController: classViewController
                )
            )
        }
        if tabConfiguration.needsRelationships {
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .arrowTriangle2Circlepath),
                    selectedSymbol: .init(systemName: .arrowTriangle2Circlepath),
                    viewController: relationshipsViewController
                )
            )
        }
        if tabConfiguration.needsSpecialization {
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .curlybracesSquare),
                    selectedSymbol: .init(systemName: .curlybracesSquareFill),
                    viewController: specializationViewController
                )
            )
        }
        return tabViewItems
    }
}

extension InspectorRuntimeObjectCoordinator {
    static func canInspect(_ runtimeObject: RuntimeObject) -> Bool {
        TabConfiguration.compute(for: runtimeObject).hasAnyTab
    }
}

extension InspectorRuntimeObjectCoordinator {
    private struct TabConfiguration: Equatable {
        let needsClassHierarchy: Bool
        let needsRelationships: Bool
        let needsSpecialization: Bool

        static let empty = Self(needsClassHierarchy: false, needsRelationships: false, needsSpecialization: false)

        var hasAnyTab: Bool { needsClassHierarchy || needsRelationships || needsSpecialization }

        var classHierarchyIndex: Int? {
            needsClassHierarchy ? 0 : nil
        }

        var relationshipsIndex: Int? {
            guard needsRelationships else { return nil }
            return needsClassHierarchy ? 1 : 0
        }

        var specializationIndex: Int? {
            guard needsSpecialization else { return nil }
            var index = 0
            if needsClassHierarchy { index += 1 }
            if needsRelationships { index += 1 }
            return index
        }

        func index(for tabKind: TabKind) -> Int? {
            switch tabKind {
            case .classHierarchy: return classHierarchyIndex
            case .relationships: return relationshipsIndex
            case .specialization: return specializationIndex
            }
        }

        func tabKind(at index: Int) -> TabKind? {
            var orderedTabKinds: [TabKind] = []
            if needsClassHierarchy { orderedTabKinds.append(.classHierarchy) }
            if needsRelationships { orderedTabKinds.append(.relationships) }
            if needsSpecialization { orderedTabKinds.append(.specialization) }
            guard index >= 0, index < orderedTabKinds.count else { return nil }
            return orderedTabKinds[index]
        }

        static func compute(for runtimeObject: RuntimeObject) -> TabConfiguration {
            let needsRelationships: Bool
            switch runtimeObject.kind {
            case .objc(.type(.class)), .objc(.type(.protocol)),
                 .swift(.type(.class)), .swift(.type(.protocol)):
                needsRelationships = true
            default:
                needsRelationships = false
            }
            switch runtimeObject.kind {
            case .objc(.type(.class)):
                return .init(needsClassHierarchy: true, needsRelationships: needsRelationships, needsSpecialization: false)
            case .objc(.type(.protocol)):
                return .init(needsClassHierarchy: false, needsRelationships: needsRelationships, needsSpecialization: false)
            case .swift(.type):
                let isClass: Bool
                if case .swift(.type(.class)) = runtimeObject.kind {
                    isClass = true
                } else {
                    isClass = false
                }
                let isGeneric = runtimeObject.properties.contains(.isGeneric)
                let isSpecialized = runtimeObject.properties.contains(.isSpecialized)
                return .init(
                    needsClassHierarchy: isClass,
                    needsRelationships: needsRelationships,
                    needsSpecialization: isGeneric && !isSpecialized
                )
            default:
                return .init(needsClassHierarchy: false, needsRelationships: false, needsSpecialization: false)
            }
        }
    }
}

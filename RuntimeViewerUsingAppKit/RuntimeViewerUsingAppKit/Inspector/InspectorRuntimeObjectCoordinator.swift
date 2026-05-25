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

    let runtimeObject: RuntimeObject

    private let tabConfiguration: TabConfiguration

    private let preferredTabKind: TabKind?

    init(documentState: DocumentState, runtimeObject: RuntimeObject, preferredTabKind: TabKind? = nil) {
        self.documentState = documentState
        self.runtimeObject = runtimeObject
        self.tabConfiguration = .compute(for: runtimeObject)
        self.preferredTabKind = preferredTabKind
        super.init(rootViewController: .init(), initialRoute: .initial)
        let configuration = tabConfiguration
        rootViewController.onUserSelectIndex = { [weak self] index in
            guard let self else { return }
            guard let tabKind = configuration.tabKind(at: index) else { return }
            delegate?.inspectorRuntimeObjectCoordinator(self, didSelectTab: tabKind)
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

    private func makeTabViewItems() -> [TabViewItem] {
        var tabViewItems: [TabViewItem] = []
        if tabConfiguration.needsClassHierarchy {
            let viewController = InspectorClassViewController()
            let viewModel = InspectorClassViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .squareStack3dUp),
                    selectedSymbol: .init(systemName: .squareStack3dUpFill),
                    viewController: viewController
                )
            )
        }
        if tabConfiguration.needsRelationships {
            let viewController = InspectorRelationshipsViewController()
            let viewModel = InspectorRelationshipsViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .arrowTriangle2Circlepath),
                    selectedSymbol: .init(systemName: .arrowTriangle2Circlepath),
                    viewController: viewController
                )
            )
        }
        if tabConfiguration.needsSpecialization {
            let viewController = InspectorSwiftSpecializationViewController()
            let viewModel = InspectorSwiftSpecializationViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            tabViewItems.append(
                TabViewItem(
                    normalSymbol: .init(systemName: .curlybracesSquare),
                    selectedSymbol: .init(systemName: .curlybracesSquareFill),
                    viewController: viewController
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
    fileprivate struct TabConfiguration {
        let needsClassHierarchy: Bool
        let needsRelationships: Bool
        let needsSpecialization: Bool

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

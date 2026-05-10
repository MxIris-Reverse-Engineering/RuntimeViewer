import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias InspectorRuntimeObjectTransition = Transition<Void, InspectorRuntimeObjectTabViewController>

final class InspectorRuntimeObjectCoordinator: ViewCoordinator<InspectorRuntimeObjectRoute, InspectorRuntimeObjectTransition> {
    protocol Delegate: AnyObject {
        func inspectorRuntimeObjectCoordinator(
            _ coordinator: InspectorRuntimeObjectCoordinator,
            didRequestSpecializationSheetFor object: RuntimeObject
        )
        func inspectorRuntimeObjectCoordinator(
            _ coordinator: InspectorRuntimeObjectCoordinator,
            didSelectRuntimeObject object: RuntimeObject
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    let runtimeObject: RuntimeObject

    private let tabConfiguration: TabConfiguration

    init(documentState: DocumentState, runtimeObject: RuntimeObject) {
        self.documentState = documentState
        self.runtimeObject = runtimeObject
        self.tabConfiguration = .compute(for: runtimeObject)
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: InspectorRuntimeObjectRoute) -> InspectorRuntimeObjectTransition {
        switch route {
        case .initial:
            return .set(makeTabViewItems())
        case .classHierarchy:
            guard let index = tabConfiguration.classHierarchyIndex else { return .none() }
            return .select(index: index)
        case .specialization:
            guard let index = tabConfiguration.specializationIndex else { return .none() }
            return .select(index: index)
        case .requestSpecializationSheet(let object):
            delegate?.inspectorRuntimeObjectCoordinator(self, didRequestSpecializationSheetFor: object)
            return .none()
        case .selectRuntimeObject(let object):
            delegate?.inspectorRuntimeObjectCoordinator(self, didSelectRuntimeObject: object)
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
        let needsSpecialization: Bool

        var hasAnyTab: Bool { needsClassHierarchy || needsSpecialization }

        var classHierarchyIndex: Int? {
            needsClassHierarchy ? 0 : nil
        }

        var specializationIndex: Int? {
            guard needsSpecialization else { return nil }
            return needsClassHierarchy ? 1 : 0
        }

        static func compute(for runtimeObject: RuntimeObject) -> TabConfiguration {
            switch runtimeObject.kind {
            case .objc(.type(.class)):
                return .init(needsClassHierarchy: true, needsSpecialization: false)
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
                    needsSpecialization: isGeneric && !isSpecialized
                )
            default:
                return .init(needsClassHierarchy: false, needsSpecialization: false)
            }
        }
    }
}

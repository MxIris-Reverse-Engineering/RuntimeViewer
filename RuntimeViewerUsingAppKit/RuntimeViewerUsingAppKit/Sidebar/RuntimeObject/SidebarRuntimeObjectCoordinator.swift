import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRuntimeObjectTransition = Transition<Void, SidebarRuntimeObjectTabViewController>

final class SidebarRuntimeObjectCoordinator: ViewCoordinator<SidebarRuntimeObjectRoute, SidebarRuntimeObjectTransition> {
    let documentState: DocumentState

    let imageNode: RuntimeImageNode

    init(documentState: DocumentState, imageNode: RuntimeImageNode) {
        self.documentState = documentState
        self.imageNode = imageNode
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: SidebarRuntimeObjectRoute) -> SidebarRuntimeObjectTransition {
        switch route {
        case .initial:
            let listViewController = SidebarRuntimeObjectListViewController()
            let listViewModel = SidebarRuntimeObjectListViewModel(imageNode: imageNode, documentState: documentState, router: self)
            listViewController.setupBindings(for: listViewModel)

            let bookmarkViewController = SidebarRuntimeObjectBookmarkViewController()
            let bookmarkViewModel = SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: documentState, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)

            return .set([
                TabViewItem(normalSymbol: .init(systemName: .folder), selectedSymbol: .init(systemName: .folderFill), viewController: listViewController),
                TabViewItem(normalSymbol: .init(systemName: .bookmark), selectedSymbol: .init(systemName: .bookmarkFill), viewController: bookmarkViewController),
            ])
        case .objects:
            return .select(index: 0)
        case .bookmarks:
            return .select(index: 1)
        case .scope(let sender, let relay, let availableKinds, let availableProperties):
            let viewController = SidebarRuntimeObjectScopeViewController()
            let viewModel = SidebarRuntimeObjectScopeViewModel<SidebarRuntimeObjectRoute>(
                relay: relay,
                availableKinds: availableKinds,
                availableProperties: availableProperties,
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            // Plain NSPopover via CocoaCoordinator's `GlobalPopover`. Using
            // `.uxPopover` here would route through `UXPopoverController`,
            // which bridges UXViewController's private `preferredContentSize`
            // ivar to NSPopover via KVO — and that bridge re-emits CA-
            // interpolated intermediate values, causing the popover to
            // animate through zero height during disclosure expansion.
            return .popover(
                viewController,
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .maxY,
                behavior: .transient
            )
        }
    }
}

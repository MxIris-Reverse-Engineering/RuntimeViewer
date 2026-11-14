import Foundation
import RuntimeViewerArchitectures
import MemberwiseInit

/// One editor pane's view model: its tab bar, its jump bar, whether it has the
/// focus, and the button that closes it.
///
/// The tab bar follows Xcode 27.2's rule: it shows in every pane as soon as any
/// pane has a second tab, and in none otherwise. The jump bar (proposal
/// `editor-jump-bar`) shows while the active tab shows an image or an object,
/// and not over an empty tab, where Xcode shows "No Selection"; while the tab
/// bar is hidden it holds the button that closes the pane, as Xcode's does.
/// Before the jump bar the tab bar showed over a single tab as soon as there was
/// a second pane, only to hold that button (proposal `editor-panes`).
public final class EditorPaneViewModel: ViewModel<EditorAreaRoute> {
    public let paneID: EditorPane.ID

    public init(paneID: EditorPane.ID, documentState: DocumentState, router: any Router<EditorAreaRoute>) {
        self.paneID = paneID
        super.init(documentState: documentState, router: router)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let tabSelected: Signal<DocumentTab.ID>
        public let tabClosed: Signal<DocumentTab.ID>
        public let closeButtonClicked: Signal<Void>
        /// A click in the pane that no view inside it took: the pane gets the
        /// focus, as a click in an Xcode editor does.
        public let backgroundClicked: Signal<Void>
        /// A command chosen in a tab's context menu (`commands(forTab:)`).
        @Init(default: Signal<(command: EditorTabCommand, tabID: DocumentTab.ID)>.empty())
        public let tabCommandChosen: Signal<(command: EditorTabCommand, tabID: DocumentTab.ID)>
        /// The pane's tabs in the order a drag in the bar left them.
        @Init(default: Signal<[DocumentTab.ID]>.empty())
        public let tabsReordered: Signal<[DocumentTab.ID]>
        /// An image or an object chosen in the pane's jump bar (proposal `editor-jump-bar`).
        @Init(default: Signal<EditorJumpBarChoice>.empty())
        public let jumpBarChoiceSelected: Signal<EditorJumpBarChoice>
    }

    /// The commands the context menu of `tabID` offers, in menu order: Close
    /// Tab; Close Other Tabs when the pane has another tab; Close Tabs to the
    /// Right when the tab is not its pane's last; then the commands on the
    /// object it shows, less Open in New Tab and Open Generated Interface,
    /// which act on the focused pane's tab rather than this one. Empty for a
    /// tab the pane no longer holds.
    public func commands(forTab tabID: DocumentTab.ID) -> [EditorTabCommand] {
        guard let pane = documentState.editorArea[paneID], let tabIndex = pane.index(ofTab: tabID) else { return [] }
        var commands: [EditorTabCommand] = [.close]
        if pane.tabs.count > 1 {
            commands.append(.closeOthers)
        }
        if tabIndex < pane.tabs.count - 1 {
            commands.append(.closeToTheRight)
        }
        if let runtimeObject = pane.tabs[tabIndex].object {
            commands += RuntimeObjectAction.actions(for: runtimeObject)
                .filter { $0 != .openInNewTab && $0 != .openGeneratedInterface }
                .map(EditorTabCommand.runtimeObjectAction)
        }
        return commands
    }

    /// Carries out a tab's context menu command. Tabs close one at a time
    /// through `closeTab`, the path the tabs' close buttons take; which ones is
    /// read before the first goes, as every close reshapes the pane.
    private func run(_ command: EditorTabCommand, onTab tabID: DocumentTab.ID) {
        guard let pane = documentState.editorArea[paneID], let tabIndex = pane.index(ofTab: tabID) else { return }
        switch command {
        case .close:
            documentState.selectionRouter.trigger(.closeTab(tabID))
        case .closeOthers:
            for otherTab in pane.tabs where otherTab.id != tabID {
                documentState.selectionRouter.trigger(.closeTab(otherTab.id))
            }
        case .closeToTheRight:
            for laterTab in pane.tabs[(tabIndex + 1)...] {
                documentState.selectionRouter.trigger(.closeTab(laterTab.id))
            }
        case .runtimeObjectAction(let action):
            #if os(macOS)
            guard let runtimeObject = pane.tabs[tabIndex].object else { return }
            perform(action, on: runtimeObject)
            #endif
        }
    }

    /// The one tab a drag moved from `originalOrder` to `reorderedOrder`, and
    /// the index it now has: the tab without which both orders are the same.
    /// `nil` when nothing moved, or when the two orders do not hold the same
    /// tabs.
    static func movedTab(from originalOrder: [DocumentTab.ID], to reorderedOrder: [DocumentTab.ID]) -> (tabID: DocumentTab.ID, destinationIndex: Int)? {
        guard originalOrder != reorderedOrder, Set(originalOrder) == Set(reorderedOrder) else { return nil }
        for (destinationIndex, tabID) in reorderedOrder.enumerated()
            where originalOrder.filter({ $0 != tabID }) == reorderedOrder.filter({ $0 != tabID }) {
            return (tabID, destinationIndex)
        }
        return nil
    }

    public struct Output {
        public let tabBarSnapshot: Driver<TabBarSnapshot>
        /// Hidden unless some pane of the editor area has a second tab.
        public let isTabBarHidden: Driver<Bool>
        public let isFocused: Driver<Bool>
        /// Hidden while closing the pane would change nothing (`EditorArea.canClosePane(_:)`): it is
        /// the only pane, and holds one tab that has shown nothing. It sits in the tab bar while that
        /// shows, and in the jump bar otherwise.
        public let isCloseButtonHidden: Driver<Bool>
        /// What the pane's jump bar shows the path to: the step on screen in its active tab.
        public let jumpBarLocation: Driver<EditorJumpBarLocation>
        /// Hidden while the active tab shows nothing: the jump bar shows only over an image or an
        /// object.
        public let isJumpBarHidden: Driver<Bool>
    }

    public func transform(_ input: Input) -> Output {
        input.tabSelected.emitOnNext { [weak self] tabID in
            guard let self else { return }
            documentState.selectionRouter.trigger(.switchTab(tabID))
        }
        .disposed(by: rx.disposeBag)

        input.tabClosed.emitOnNext { [weak self] tabID in
            guard let self else { return }
            documentState.selectionRouter.trigger(.closeTab(tabID))
        }
        .disposed(by: rx.disposeBag)

        input.closeButtonClicked.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.closeEditorPane(paneID))
        }
        .disposed(by: rx.disposeBag)

        input.backgroundClicked.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.focusEditorPane(paneID))
        }
        .disposed(by: rx.disposeBag)

        input.tabCommandChosen.emitOnNext { [weak self] command, tabID in
            guard let self else { return }
            run(command, onTab: tabID)
        }
        .disposed(by: rx.disposeBag)

        input.tabsReordered.emitOnNext { [weak self] reorderedOrder in
            guard let self,
                  let pane = documentState.editorArea[paneID],
                  let move = Self.movedTab(from: pane.tabs.map(\.id), to: reorderedOrder)
            else { return }
            documentState.selectionRouter.trigger(.moveTab(move.tabID, toIndex: move.destinationIndex))
        }
        .disposed(by: rx.disposeBag)

        // Chosen in this pane's jump bar, so it opens from this pane: the pane takes the focus
        // first, and the focused tab, a new tab and the next pane are reckoned from it. The sidebar
        // stays where it is.
        input.jumpBarChoiceSelected.emitOnNext { [weak self] choice in
            guard let self else { return }
            documentState.selectionRouter.trigger(.focusEditorPane(paneID))
            documentState.selectionRouter.trigger(choice.route)
        }
        .disposed(by: rx.disposeBag)

        // A pane that has just closed is not looked up any more: its view goes
        // away with it.
        let paneID = paneID
        let editorArea = documentState.$editorArea.asDriver()
        let pane = editorArea.compactMap { $0[paneID] }
        let tabBarSnapshot = pane.map(TabBarSnapshot.init(pane:)).distinctUntilChanged()
        let jumpBarLocation = pane.map { EditorJumpBarLocation(entry: $0.activeTab.currentEntry) }.distinctUntilChanged()

        return Output(
            tabBarSnapshot: tabBarSnapshot,
            isTabBarHidden: editorArea.map { editorArea in
                !editorArea.panes.values.contains { $0.tabs.count > 1 }
            }
            .distinctUntilChanged(),
            isFocused: editorArea.map { $0.focusedPaneID == paneID }.distinctUntilChanged(),
            isCloseButtonHidden: editorArea.map { !$0.canClosePane(paneID) }.distinctUntilChanged(),
            jumpBarLocation: jumpBarLocation,
            isJumpBarHidden: jumpBarLocation.map { $0 == .nothing }.distinctUntilChanged()
        )
    }
}

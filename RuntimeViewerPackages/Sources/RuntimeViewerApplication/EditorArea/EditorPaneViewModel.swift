import Foundation
import RuntimeViewerArchitectures
import MemberwiseInit

/// One editor pane's view model: its tab bar, whether it has the focus, and the
/// button that closes it.
///
/// The tab bar shows as soon as the editor area has a second pane, even over a
/// single tab: RuntimeViewer has no jump bar, which is what shows the focused
/// pane and holds the close button in Xcode, so without it nothing would say
/// which pane has the focus. With one pane it shows from the second tab on, as
/// before panes existed (proposal `editor-panes`).
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
    }

    public struct Output {
        public let tabBarSnapshot: Driver<TabBarSnapshot>
        public let isTabBarHidden: Driver<Bool>
        public let isFocused: Driver<Bool>
        /// Hidden while the pane is the only one: the only pane cannot be closed.
        public let isCloseButtonHidden: Driver<Bool>
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

        // A pane that has just closed is not looked up any more: its view goes
        // away with it.
        let paneID = paneID
        let editorArea = documentState.$editorArea.asDriver()
        let pane = editorArea.compactMap { $0[paneID] }
        let paneCount = editorArea.map(\.panes.count).distinctUntilChanged()
        let tabBarSnapshot = pane.map(TabBarSnapshot.init(pane:)).distinctUntilChanged()

        return Output(
            tabBarSnapshot: tabBarSnapshot,
            isTabBarHidden: Driver.combineLatest(paneCount, tabBarSnapshot.map(\.items.count)) { paneCount, tabCount in
                paneCount < 2 && tabCount < 2
            }
            .distinctUntilChanged(),
            isFocused: editorArea.map { $0.focusedPaneID == paneID }.distinctUntilChanged(),
            isCloseButtonHidden: paneCount.map { $0 < 2 }.distinctUntilChanged()
        )
    }
}

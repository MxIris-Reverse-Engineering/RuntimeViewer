import AppKit
import RxCocoa
import RxSwift

final class BackgroundIndexingToolbarItem: NSToolbarItem {
    static let identifier = NSToolbarItem.Identifier("backgroundIndexing")

    let itemView = BackgroundIndexingToolbarItemView()
    let tapRelay = PublishRelay<NSView>()
    private let disposeBag = DisposeBag()

    init() {
        super.init(itemIdentifier: Self.identifier)
        label = "Indexing"
        paletteLabel = "Background Indexing"
        toolTip = "Background indexing status"
        view = itemView

        // The actual click receiver is the button inside `itemView`. The
        // toolbar item's own target/action is also wired so the item works
        // when it appears in the overflow menu (where there is no view).
        itemView.button.target = self
        itemView.button.action = #selector(clicked)
        target = self
        action = #selector(clicked)
    }

    @objc private func clicked() {
        tapRelay.accept(itemView)
    }
}

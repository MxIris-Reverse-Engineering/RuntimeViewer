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
        target = self
        action = #selector(clicked)
    }

    func bindState(_ driver: Driver<BackgroundIndexingToolbarState>) {
        driver.driveOnNext { [weak self] state in
            guard let self else { return }
            itemView.state = state
        }
        .disposed(by: disposeBag)
    }

    @objc private func clicked() {
        tapRelay.accept(itemView)
    }
}

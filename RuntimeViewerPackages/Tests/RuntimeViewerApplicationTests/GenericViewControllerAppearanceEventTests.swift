import AppKit
import Foundation
import RuntimeViewerArchitectures
import Testing

/// RxAppKit's `rx.viewWillAppear` / `rx.viewWillDisappear` on a generic view controller. They
/// intercept the method through RxCocoa's `methodInvoked`, which swaps in a subclass made at run
/// time, and no generic controller in this project relied on them before the Report navigator's
/// page did: it builds its tree only while it is on screen, from these two events (PR121.59).
@Suite("Generic view controller appearance events")
@MainActor
struct GenericViewControllerAppearanceEventTests {
    /// The shape of `ReportViewController<Route>`: a generic subclass of `NSViewController`.
    private final class GenericPageViewController<Payload>: NSViewController {
        override func loadView() {
            view = NSView()
        }
    }

    @Test("a generic view controller reports that it will appear and will disappear")
    func appearanceEventsReachAGenericViewController() {
        let viewController = GenericPageViewController<Int>()
        var events: [String] = []
        let disposeBag = DisposeBag()
        Observable.merge(
            viewController.rx.viewWillAppear.map { "will appear" },
            viewController.rx.viewWillDisappear.map { "will disappear" }
        )
        .subscribeOnNext { event in events.append(event) }
        .disposed(by: disposeBag)

        viewController.viewWillAppear()
        viewController.viewWillDisappear()
        viewController.viewWillAppear()

        #expect(events == ["will appear", "will disappear", "will appear"])
    }
}

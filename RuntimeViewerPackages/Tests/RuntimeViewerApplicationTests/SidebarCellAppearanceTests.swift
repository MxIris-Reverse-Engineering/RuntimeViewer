import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// Pins the atomic-appearance contract introduced by proposal 0005: a cell
/// view model publishes its entire visual state as ONE
/// `RuntimeObjectCellAppearance` event per actual change, and equal-value
/// updates are suppressed instead of re-published.
@Suite("SidebarCellAppearance")
@MainActor
struct SidebarCellAppearanceTests {
    @Test("fuzzy filter transitions publish one appearance event each; identical reapplication publishes none")
    func filterTransitionsPublishAtomically() {
        let cellViewModel = SidebarRuntimeObjectCellViewModel(
            runtimeObject: makeRuntimeObject(displayName: "TestFramework.NeedleGeneratedType"),
            forOpenQuickly: false
        )
        let counter = AppearanceEmissionCounter(observing: cellViewModel)

        // Gaining a highlight changes only the title, but the event carries
        // the whole appearance — exactly one emission.
        let fuzzyNeedleContext = FilterContext(query: "Needle", isCaseInsensitive: false, mode: .fuzzySearch)
        let matches = FilterEngine.filter(context: fuzzyNeedleContext, items: [cellViewModel])
        #expect(matches.count == 1)
        #expect(counter.emissionCount == 1)

        // Re-running the identical query re-fires the filterResult didSet
        // with a fresh result object, so the title genuinely rebuilds — but
        // it compares equal and the equal-value appearance must be dropped.
        counter.reset()
        _ = FilterEngine.filter(context: fuzzyNeedleContext, items: [cellViewModel])
        #expect(counter.emissionCount == 0)

        // Clearing restores the default title: exactly one event again.
        counter.reset()
        _ = FilterEngine.filter(
            context: FilterContext(query: "", isCaseInsensitive: false, mode: .fuzzySearch),
            items: [cellViewModel]
        )
        #expect(counter.emissionCount == 1)
    }

    @Test("a runtimeObject change publishes icons and title in a single event")
    func runtimeObjectChangePublishesOneEvent() {
        let cellViewModel = SidebarRuntimeObjectCellViewModel(
            runtimeObject: makeRuntimeObject(displayName: "TestFramework.GenericType"),
            forOpenQuickly: false
        )
        #expect(cellViewModel.appearance.tertiaryIcon == nil)
        let counter = AppearanceEmissionCounter(observing: cellViewModel)

        // Same display name, new `.isGeneric` flag: the refresh adds the
        // tertiary icon. Pre-0005 this fanned out over five relays; now it
        // must be one atomic event.
        cellViewModel.runtimeObject = makeRuntimeObject(
            displayName: "TestFramework.GenericType",
            properties: [.isGeneric]
        )

        #expect(counter.emissionCount == 1)
        #expect(cellViewModel.appearance.tertiaryIcon != nil)
    }

    @Test("a splice that leaves this row's display state untouched publishes no event")
    func displayNeutralSplicePublishesNoEvent() {
        let child = makeRuntimeObject(displayName: "TestFramework.Parent.Child")
        let parent = makeRuntimeObject(displayName: "TestFramework.Parent", children: [child])
        let parentCellViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: parent, forOpenQuickly: false)
        let counter = AppearanceEmissionCounter(observing: parentCellViewModel)

        let splicedChild = makeRuntimeObject(displayName: "TestFramework.Parent.SplicedChild")
        #expect(parentCellViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(splicedChild))

        // The parent's own name, kind and properties are unchanged, so the
        // recomposed appearance compares equal (icons are cache-stable) and
        // nothing reaches the cell view.
        #expect(counter.emissionCount == 0)
        #expect(parentCellViewModel.children.count == 2)
    }

    // MARK: - Fixtures

    private func makeRuntimeObject(
        displayName: String,
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: displayName,
            displayName: displayName,
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: children,
            properties: properties
        )
    }
}

/// Counts `$appearance` relay emissions on a single cell view model.
/// `@RxObserved` is backed by a `BehaviorRelay`, so emissions land
/// synchronously and the counts asserted above are exact.
@MainActor
private final class AppearanceEmissionCounter {
    private(set) var emissionCount = 0

    private let disposeBag = DisposeBag()

    init(observing cellViewModel: SidebarRuntimeObjectCellViewModel) {
        cellViewModel.$appearance
            .skip(1) // BehaviorRelay replays the current appearance on subscribe
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                emissionCount += 1
            }
            .disposed(by: disposeBag)
    }

    func reset() {
        emissionCount = 0
    }
}

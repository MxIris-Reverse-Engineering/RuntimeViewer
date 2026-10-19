import AppKit
import Testing
import RuntimeViewerUI

/// How the sections of the Inspector's References tab share the Inspector: the lists whose rows fit
/// take just that, the others split the rest, and the page scrolls only below every section's minimum.
@Suite("Stacked height sharing")
struct StackedHeightSharingTests {
    private typealias Demand = StackedHeightSharing.Demand

    @Test("views that all fit take what they ask for, and leave the rest of the height empty")
    func everythingFits() {
        let heights = StackedHeightSharing.heights(for: [Demand(minimum: 40, preferred: 100), Demand(minimum: 30, preferred: 60)], spacing: 16, in: 600)
        #expect(heights == [100, 60])
    }

    @Test("a list too long for the height takes everything the others leave, down to the bottom")
    func oneListTakesTheRest() {
        // The callers fit; the type's references run to the bottom: 600 - 16 - 120.
        let heights = StackedHeightSharing.heights(for: [Demand(minimum: 60, preferred: 120), Demand(minimum: 100, preferred: 3000)], spacing: 16, in: 600)
        #expect(heights == [120, 464])
    }

    @Test("lists too long for the height split what the ones that fit leave evenly")
    func longListsSplitEvenly() {
        // 632 - 2 × 16 = 600; the first list takes its 120, the other two 240 each.
        let demands = [Demand(minimum: 60, preferred: 120), Demand(minimum: 100, preferred: 3000), Demand(minimum: 100, preferred: 2000)]
        #expect(StackedHeightSharing.heights(for: demands, spacing: 16, in: 632) == [120, 240, 240])
    }

    @Test("a view that cannot shrink keeps its height, and the lists share what is left")
    func fixedViewKeepsItsHeight() {
        // A message: its minimum is everything it shows.
        let demands = [Demand(minimum: 200, preferred: 200), Demand(minimum: 100, preferred: 3000), Demand(minimum: 60, preferred: 1000)]
        #expect(StackedHeightSharing.heights(for: demands, spacing: 0, in: 500) == [200, 150, 150])
    }

    @Test("a view keeps its minimum where an even share is less, and the others share the rest")
    func minimumAboveAnEvenShare() {
        // An even share would be 33; the middle view needs 70, so the other two get 15 each.
        let demands = [Demand(minimum: 0, preferred: 40), Demand(minimum: 70, preferred: 200), Demand(minimum: 0, preferred: 200)]
        #expect(StackedHeightSharing.heights(for: demands, spacing: 0, in: 100) == [15, 70, 15])
    }

    @Test("too short for the minimums, every view gets its minimum and the stack runs past the height")
    func tooShortForTheMinimums() {
        let demands = [Demand(minimum: 100, preferred: 300), Demand(minimum: 100, preferred: 300)]
        #expect(StackedHeightSharing.heights(for: demands, spacing: 16, in: 150) == [100, 100])
        #expect(StackedHeightSharing.minimumHeight(of: demands, spacing: 16) == 216)
    }

    @Test("a preferred height under the minimum counts as the minimum")
    func preferredUnderTheMinimum() {
        #expect(StackedHeightSharing.heights(for: [Demand(minimum: 80, preferred: 20)], spacing: 16, in: 600) == [80])
    }

    @Test("nothing to stack takes nothing")
    func nothingToStack() {
        #expect(StackedHeightSharing.heights(for: [], spacing: 16, in: 600).isEmpty)
        #expect(StackedHeightSharing.minimumHeight(of: [], spacing: 16) == 0)
    }
}

/// The placeholder's own account of its height, which a layout that sizes its parts itself makes room
/// by, against the height Auto Layout gives it.
@Suite("Skeleton placeholder height")
@MainActor
struct SkeletonPlaceholderHeightTests {
    @Test("the content height is the height the placeholder lays out at", arguments: [1, 5])
    func contentHeightMatchesTheLayout(rowCount: Int) {
        let placeholderView = SkeletonPlaceholderView.runtimeObjectList(rowCount: rowCount)
        #expect(placeholderView.contentHeight == placeholderView.fittingSize.height)
    }
}

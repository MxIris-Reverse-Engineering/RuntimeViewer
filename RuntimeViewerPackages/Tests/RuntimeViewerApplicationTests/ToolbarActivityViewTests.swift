import AppKit
import Foundation
import Testing
@testable import RuntimeViewerUI

/// The toolbar's activity capsule below macOS 27 — Xcode 26's Activity View without its scheme
/// picker: when its indicator shows, how its text reads, which version of the text fits, and the
/// ring's spin (proposal `draft-xcode-activity-progress`; spec in `/Volumes/RE/Xcode/26.6/README.md`).
@Suite("Toolbar activity view")
@MainActor
struct ToolbarActivityViewTests {
    private static func runningState(percent: Int?, activityCount: Int = 1) -> ToolbarActivityState {
        ToolbarActivityState(
            reportIdentifier: UUID(),
            isCompleted: false,
            segments: [
                ActivityTextSegment("Indexing", priority: 2, separator: .primary),
                ActivityTextSegment("12 of 48 images", priority: 1),
            ],
            progress: percent.map { .determinate(percent: $0) } ?? .indeterminate,
            activityCount: activityCount
        )
    }

    private static let completedState = ToolbarActivityState(
        reportIdentifier: UUID(),
        isCompleted: true,
        segments: [
            ActivityTextSegment("Indexing", priority: 2, separator: .space),
            ActivityTextSegment("Succeeded", priority: 1, isEmphasized: true, separator: .primary),
            ActivityTextSegment("Today at 19:33", priority: 3),
        ],
        progress: nil,
        activityCount: 1
    )

    @Test("The indicator shows for one activity under way once its progress is past 0, or not known")
    func indicatorShowsForProgressPastZero() {
        #expect(ToolbarActivityView.showsIndicator(for: Self.runningState(percent: 0)) == false)
        #expect(ToolbarActivityView.showsIndicator(for: Self.runningState(percent: 1)))
        #expect(ToolbarActivityView.showsIndicator(for: Self.runningState(percent: nil)))
    }

    @Test("The indicator shows whenever there are several activities, and not for one that ended")
    func indicatorShowsForSeveralActivities() {
        var completedWithOthers = Self.completedState
        completedWithOthers.activityCount = 2

        #expect(ToolbarActivityView.showsIndicator(for: Self.completedState) == false)
        #expect(ToolbarActivityView.showsIndicator(for: completedWithOthers))
        #expect(ToolbarActivityView.showsIndicator(for: Self.runningState(percent: 0, activityCount: 2)))
    }

    @Test("The text joins its segments with the box-drawing bar and puts the outcome in bold")
    func attributedTextReadsLikeXcode() throws {
        let text = ToolbarActivityView.attributedText(for: Self.completedState.segments)

        #expect(text.string == "Indexing Succeeded \u{2502} Today at 19:33")
        let outcomeRange = (text.string as NSString).range(of: "Succeeded")
        let outcomeFont = try #require(text.attribute(.font, at: outcomeRange.location, effectiveRange: nil) as? NSFont)
        let subjectFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(outcomeFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(subjectFont.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(subjectFont.pointSize == 11)
    }

    @Test("A wide capsule shows the whole text; a narrow one drops the title before the count")
    func narrowCapsuleDropsSegments() {
        let activityView = ToolbarActivityView()
        activityView.apply(Self.runningState(percent: 25), animated: false)

        activityView.frame = NSRect(x: 0, y: 0, width: 600, height: 24)
        activityView.layoutSubtreeIfNeeded()
        let wideText = activityView.displayedText

        activityView.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        activityView.layoutSubtreeIfNeeded()
        let narrowText = activityView.displayedText

        #expect(wideText == "Indexing \u{2502} 12 of 48 images")
        #expect(narrowText == "12 of 48 images")
        #expect(activityView.isShowingIndicator)
    }

    @Test("When the run ends the indicator goes, its ring keeping the last value while it fades")
    func ringKeepsItsLastValueWhileFading() {
        let activityView = ToolbarActivityView()
        var runningState = Self.runningState(percent: 40)
        activityView.apply(runningState, animated: false)
        runningState.isCompleted = true
        runningState.progress = nil

        activityView.apply(runningState, animated: true)

        #expect(activityView.isShowingIndicator == false)
        #expect(activityView.shownRingValue == .determinate(40))
    }

    @Test("The ring spins while the progress is not known, and stops once it is")
    func ringSpinsOnlyWhileIndeterminate() throws {
        let ring = ActivityProgressRing(ringSize: 16)
        let sublayers = try #require(ring.layer?.sublayers)
        let isSpinning = { sublayers.contains { $0.animation(forKey: ActivityProgressRing.rotationAnimationKey) != nil } }

        ring.setValue(.indeterminate, animated: true)
        let spinsWhileIndeterminate = isSpinning()
        ring.setValue(.determinate(40), animated: true)
        let spinsOnceDeterminate = isSpinning()

        #expect(spinsWhileIndeterminate)
        #expect(spinsOnceDeterminate == false)
        #expect(ring.value == .determinate(40))
    }
}

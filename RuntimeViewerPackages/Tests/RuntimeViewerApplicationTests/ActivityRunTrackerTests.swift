import Foundation
import Testing
@testable import RuntimeViewerApplication

/// One kind of background work followed from run to run: what makes a run, how far it is, and how
/// it ended — the activity display's raw material (proposal `draft-xcode-activity-progress`).
@Suite("Activity run tracker")
struct ActivityRunTrackerTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("Nothing under way starts no run")
    func nothingUnderWayStartsNoRun() {
        var tracker = ActivityRunTracker(kind: .backgroundIndexing)

        let endedReport = tracker.update(items: [ActivityWorkItem(identifier: "UIKitCore", state: .succeeded)], now: Self.start)

        #expect(endedReport == nil)
        #expect(tracker.currentReport == nil)
    }

    @Test("A run starts when an item is under way, at that moment")
    func runStartsWithFirstActiveItem() throws {
        var tracker = ActivityRunTracker(kind: .searchableInterfaces)

        _ = tracker.update(items: [ActivityWorkItem(identifier: "UIKitCore", state: .waiting)], now: Self.start)

        let report = try #require(tracker.currentReport)
        #expect(report.kind == .searchableInterfaces)
        #expect(report.startDate == Self.start)
        #expect(report.isCompleted == false)
    }

    @Test("Progress counts the images under way by their own progress")
    func progressCountsRunningItemsByTheirProgress() throws {
        var tracker = ActivityRunTracker(kind: .backgroundIndexing)
        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .waiting),
            ActivityWorkItem(identifier: "B", state: .waiting),
            ActivityWorkItem(identifier: "C", state: .waiting),
            ActivityWorkItem(identifier: "D", state: .waiting),
        ], now: Self.start)

        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .succeeded),
            ActivityWorkItem(identifier: "B", state: .running(fractionCompleted: 0.5)),
            ActivityWorkItem(identifier: "C", state: .waiting),
            ActivityWorkItem(identifier: "D", state: .waiting),
        ], now: Self.start + 1)

        let report = try #require(tracker.currentReport)
        #expect(report.finishedCount == 1)
        #expect(report.totalCount == 4)
        #expect(report.fractionCompleted == 0.375)
    }

    @Test("Images that finished before the run started are not part of it")
    func itemsFinishedBeforeTheRunAreLeftOut() throws {
        var tracker = ActivityRunTracker(kind: .crossReferences)

        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "AppKit", state: .succeeded),
            ActivityWorkItem(identifier: "UIKitCore", state: .failed),
            ActivityWorkItem(identifier: "SwiftUI", state: .waiting),
        ], now: Self.start)

        let report = try #require(tracker.currentReport)
        #expect(report.totalCount == 1)
        #expect(report.finishedCount == 0)
    }

    @Test("Work that joins while the run lasts adds to its total, so the fraction can go down")
    func joiningWorkGrowsTheRun() throws {
        var tracker = ActivityRunTracker(kind: .backgroundIndexing)
        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .succeeded),
            ActivityWorkItem(identifier: "B", state: .waiting),
        ], now: Self.start)
        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "B", state: .succeeded),
            ActivityWorkItem(identifier: "C", state: .waiting),
        ], now: Self.start + 1)

        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "B", state: .succeeded),
            ActivityWorkItem(identifier: "C", state: .waiting),
            ActivityWorkItem(identifier: "D", state: .waiting),
            ActivityWorkItem(identifier: "E", state: .waiting),
        ], now: Self.start + 2)

        let report = try #require(tracker.currentReport)
        #expect(report.totalCount == 4)
        #expect(report.finishedCount == 1)
        #expect(report.fractionCompleted == 0.25)
    }

    @Test("The run ends when nothing in it is under way, with its outcome", arguments: [
        (finalStates: [ActivityWorkItem.State.succeeded, .succeeded], outcome: ActivityReport.Outcome.succeeded),
        (finalStates: [.succeeded, .failed], outcome: .failed),
        (finalStates: [.succeeded, .cancelled], outcome: .cancelled),
        (finalStates: [.failed, .cancelled], outcome: .failed),
    ])
    func runEndsWithOutcome(finalStates: [ActivityWorkItem.State], outcome: ActivityReport.Outcome) throws {
        var tracker = ActivityRunTracker(kind: .backgroundIndexing)
        _ = tracker.update(items: finalStates.indices.map { ActivityWorkItem(identifier: "\($0)", state: .waiting) }, now: Self.start)

        let endedReport = tracker.update(
            items: finalStates.enumerated().map { ActivityWorkItem(identifier: "\($0.offset)", state: $0.element) },
            now: Self.start + 7
        )

        let report = try #require(endedReport)
        #expect(report.completion == ActivityReport.Completion(outcome: outcome, date: Self.start + 7))
        #expect(report.finishedCount == 2)
        #expect(report.fractionCompleted == 1)
        #expect(tracker.currentReport == nil)
    }

    @Test("An image that goes away during the run counts as done and decides nothing")
    func vanishedItemEndsWithoutDecidingTheOutcome() throws {
        var tracker = ActivityRunTracker(kind: .searchableInterfaces)
        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .running(fractionCompleted: 0.2)),
            ActivityWorkItem(identifier: "B", state: .waiting),
        ], now: Self.start)

        let endedReport = tracker.update(items: [ActivityWorkItem(identifier: "A", state: .succeeded)], now: Self.start + 1)

        let report = try #require(endedReport)
        #expect(report.completion?.outcome == .succeeded)
        #expect(report.totalCount == 2)
        #expect(report.finishedCount == 2)
    }

    @Test("A run the user waits on any part of is user-requested")
    func userRequestedItemMakesTheRunUserRequested() throws {
        var tracker = ActivityRunTracker(kind: .searchableInterfaces)
        _ = tracker.update(items: [ActivityWorkItem(identifier: "A", state: .waiting)], now: Self.start)
        #expect(tracker.currentReport?.isUserRequested == false)

        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .waiting),
            ActivityWorkItem(identifier: "B", state: .waiting, isUserRequested: true),
        ], now: Self.start + 1)

        let report = try #require(tracker.currentReport)
        #expect(report.isUserRequested)
    }

    @Test("The next run is another report")
    func nextRunIsAnotherReport() throws {
        var tracker = ActivityRunTracker(kind: .backgroundIndexing)
        _ = tracker.update(items: [ActivityWorkItem(identifier: "A", state: .waiting)], now: Self.start)
        let firstEndedReport = tracker.update(items: [ActivityWorkItem(identifier: "A", state: .succeeded)], now: Self.start + 1)
        let firstReport = try #require(firstEndedReport)

        _ = tracker.update(items: [
            ActivityWorkItem(identifier: "A", state: .succeeded),
            ActivityWorkItem(identifier: "B", state: .waiting),
        ], now: Self.start + 2)

        let secondReport = try #require(tracker.currentReport)
        #expect(secondReport.id != firstReport.id)
        #expect(secondReport.startDate == Self.start + 2)
        #expect(secondReport.totalCount == 1)
    }
}

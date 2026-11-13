import Foundation

/// One item of a kind of background work — an image, mostly — as it stands at one moment.
struct ActivityWorkItem: Hashable {
    enum State: Hashable {
        /// Asked for, not started.
        case waiting
        /// Under way; with how far it is, from 0 to 1, when that is known.
        case running(fractionCompleted: Double?)
        case succeeded
        case failed
        case cancelled
        /// Gone without saying how it ended — a corpus the store gave up or evicted. It counts as
        /// done and decides nothing about the run's outcome.
        case ended

        var isActive: Bool {
            switch self {
            case .waiting, .running:
                true
            case .succeeded, .failed, .cancelled, .ended:
                false
            }
        }

        /// What the item adds to the run's progress, from 0 to 1.
        var fractionCompleted: Double {
            switch self {
            case .waiting:
                0
            case .running(let fractionCompleted):
                min(max(fractionCompleted ?? 0, 0), 1)
            case .succeeded, .failed, .cancelled, .ended:
                1
            }
        }
    }

    let identifier: String

    let state: State

    /// The user waits on this item: a Find search asked for it, or it belongs to a manual indexing.
    let isUserRequested: Bool

    init(identifier: String, state: State, isUserRequested: Bool = false) {
        self.identifier = identifier
        self.state = state
        self.isUserRequested = isUserRequested
    }
}

/// Follows one kind of background work from run to run.
///
/// Each time the kind's work changes it is handed every item the kind reports, and keeps the run
/// those items make up: a run starts when an item is under way and none was, takes in every item
/// that is under way while it lasts, and ends — completed — when none of its items is under way
/// any more. Items that finished before the run started are not part of it.
struct ActivityRunTracker {
    let kind: ReportCategory

    /// The run under way, as of the last update; `nil` between runs.
    private(set) var currentReport: ActivityReport?

    /// The last state of every item the run under way has had, by identifier.
    private var runItemStates: [String: ActivityWorkItem.State] = [:]

    init(kind: ReportCategory) {
        self.kind = kind
    }

    /// Whether the run under way has had the item.
    func isInCurrentRun(_ identifier: String) -> Bool {
        runItemStates[identifier] != nil
    }

    /// Takes in what the kind reports now — `items` need only hold the items under way and those of
    /// the run under way; others are ignored — and returns the report of a run that this update
    /// ended, completed.
    mutating func update(items: [ActivityWorkItem], now: Date) -> ActivityReport? {
        let hasActiveItem = items.contains { $0.state.isActive }
        if currentReport == nil {
            guard hasActiveItem else { return nil }
            currentReport = ActivityReport(kind: kind, startDate: now)
            runItemStates = [:]
        }
        guard var report = currentReport else { return nil }

        var reportedIdentifiers: Set<String> = []
        reportedIdentifiers.reserveCapacity(items.count)
        for item in items where item.state.isActive || runItemStates[item.identifier] != nil {
            reportedIdentifiers.insert(item.identifier)
            runItemStates[item.identifier] = item.state
            if item.isUserRequested, item.state.isActive {
                report.isUserRequested = true
            }
        }
        // An item of the run that is no longer reported at all went away without an end of its own.
        for (identifier, state) in runItemStates where state.isActive && !reportedIdentifiers.contains(identifier) {
            runItemStates[identifier] = .ended
        }

        report.totalCount = runItemStates.count
        report.finishedCount = runItemStates.values.lazy.filter { !$0.isActive }.count
        if report.totalCount > 0 {
            let completedAmount = runItemStates.values.reduce(0) { $0 + $1.fractionCompleted }
            report.fractionCompleted = completedAmount / Double(report.totalCount)
        } else {
            report.fractionCompleted = nil
        }

        guard !runItemStates.values.contains(where: \.isActive) else {
            currentReport = report
            return nil
        }
        report.completion = ActivityReport.Completion(outcome: outcome(), date: now)
        report.fractionCompleted = 1
        currentReport = nil
        runItemStates = [:]
        return report
    }

    /// How the finished run went: failed when an image failed, cancelled when one was cancelled
    /// and none failed, succeeded otherwise.
    private func outcome() -> ActivityReport.Outcome {
        if runItemStates.values.contains(.failed) {
            return .failed
        }
        if runItemStates.values.contains(.cancelled) {
            return .cancelled
        }
        return .succeeded
    }
}

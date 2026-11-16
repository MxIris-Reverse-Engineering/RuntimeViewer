import Foundation
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What `OwnerReportingTask` promises the ViewModels that show an export's
/// progress: the work never keeps its owner alive, so an owner whose sheet
/// closed goes away and its work stops with it; and once the work is
/// cancelled nothing more reaches the owner.
@Suite("OwnerReportingTask")
@MainActor
struct OwnerReportingTaskTests {
    private struct WorkFailed: Error {}

    /// What the work saw, kept apart from the owner so a test can read it
    /// after the owner is gone.
    @MainActor
    private final class WorkLog {
        var reportedCount = 0
        var wasCancelled = false
        var received: [Int] = []
        var failureCount = 0
    }

    /// Stands in for a ViewModel: holds the task and records what reaches it.
    @MainActor
    private final class Owner {
        let task = OwnerReportingTask<Int>()
        let log: WorkLog

        init(log: WorkLog) {
            self.log = log
        }

        /// Reports until cancelled, the way an export reports its objects.
        func startReportingUntilCancelled() {
            let log = log
            task.start(reportingTo: self) { report in
                var index = 0
                while !Task.isCancelled {
                    index += 1
                    report(index)
                    log.reportedCount = index
                    try? await Task.sleep(for: .milliseconds(10))
                }
                log.wasCancelled = true
            } receive: { owner, event in
                owner.log.received.append(event)
            } fail: { owner, _ in
                owner.log.failureCount += 1
            }
        }

        func start(failingWith error: any Error) {
            task.start(reportingTo: self) { _ in
                throw error
            } receive: { _, _ in
            } fail: { owner, _ in
                owner.log.failureCount += 1
            }
        }

        /// Waits until cancelled and lets the cancellation escape as an error.
        func startWaitingUntilCancelled() {
            let log = log
            task.start(reportingTo: self) { report in
                report(1)
                log.reportedCount = 1
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    log.wasCancelled = true
                    throw error
                }
            } receive: { owner, event in
                owner.log.received.append(event)
            } fail: { owner, _ in
                owner.log.failureCount += 1
            }
        }
    }

    @Test("an owner that goes away cancels its work")
    func releasingTheOwnerCancelsTheWork() async throws {
        let log = WorkLog()
        weak var releasedOwner: Owner?
        do {
            let owner = Owner(log: log)
            releasedOwner = owner
            owner.startReportingUntilCancelled()
            #expect(await pollUntil(timeout: .seconds(5)) { log.reportedCount >= 3 })
        }

        #expect(await pollUntil(timeout: .seconds(5)) { log.wasCancelled })
        #expect(releasedOwner == nil)
    }

    @Test("cancelling stops the work, and nothing reported after it reaches the owner")
    func cancellingStopsTheWork() async throws {
        let log = WorkLog()
        let owner = Owner(log: log)
        defer { withExtendedLifetime(owner) {} }
        owner.startReportingUntilCancelled()
        #expect(await pollUntil(timeout: .seconds(5)) { log.reportedCount >= 3 })

        owner.task.cancel()

        #expect(await pollUntil(timeout: .seconds(5)) { log.wasCancelled })
        let receivedCount = log.received.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.received.count == receivedCount)
        #expect(log.failureCount == 0)
    }

    @Test("a failure of the work reaches the owner")
    func failureReachesTheOwner() async throws {
        let log = WorkLog()
        let owner = Owner(log: log)
        defer { withExtendedLifetime(owner) {} }

        owner.start(failingWith: WorkFailed())

        #expect(await pollUntil(timeout: .seconds(5)) { log.failureCount == 1 })
    }

    @Test("the cancellation a cancelled work throws is not reported as a failure")
    func cancellationIsNotAFailure() async throws {
        let log = WorkLog()
        let owner = Owner(log: log)
        defer { withExtendedLifetime(owner) {} }
        owner.startWaitingUntilCancelled()
        #expect(await pollUntil(timeout: .seconds(5)) { log.reportedCount == 1 })

        owner.task.cancel()

        #expect(await pollUntil(timeout: .seconds(5)) { log.wasCancelled })
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.failureCount == 0)
    }
}

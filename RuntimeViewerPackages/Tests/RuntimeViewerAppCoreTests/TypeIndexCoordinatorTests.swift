import Foundation
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The type index coordinator follows where the engine's serving process stands with its SDK type
/// index: it asks as it starts, again on each `.typeNamesResolved` the engine broadcasts, and every
/// polling interval while a batch is queued — and stops polling once nothing is, and asking at all
/// once it is closed. The status comes from a script, not the engine: a test process has no type
/// index, so a live engine answers `.empty`.
@Suite("TypeIndexCoordinator", .serialized)
@MainActor
struct TypeIndexCoordinatorTests {
    /// The status the coordinator is answered with, and how often it asked. `@unchecked Sendable`
    /// because an `NSLock` guards it.
    private final class StatusScript: @unchecked Sendable {
        private let lock = NSLock()

        private var currentStatus: RuntimeTypeIndexStatus

        private var currentRequestCount = 0

        init(_ status: RuntimeTypeIndexStatus) {
            currentStatus = status
        }

        var status: RuntimeTypeIndexStatus {
            get { lock.withLock { currentStatus } }
            set { lock.withLock { currentStatus = newValue } }
        }

        var requestCount: Int {
            lock.withLock { currentRequestCount }
        }

        func answer() -> RuntimeTypeIndexStatus {
            lock.withLock {
                currentRequestCount += 1
                return currentStatus
            }
        }
    }

    private static let pollingIntervalNanoseconds: UInt64 = 50_000_000

    private static let building = RuntimeTypeIndexStatus(
        platforms: [.init(platformName: "macosx", sdkVersion: "27.2-27C5", phase: .building(finishedBatchCount: 1, queuedBatchCount: 3), indexedModuleCount: 12)],
        cacheByteCount: 1_000_000
    )

    private static let readyAndUnavailable = RuntimeTypeIndexStatus(
        platforms: [
            .init(platformName: "iphoneos", sdkVersion: nil, phase: .unavailable(.sdkNotInstalled), indexedModuleCount: 0),
            .init(platformName: "macosx", sdkVersion: "27.2-27C5", phase: .ready, indexedModuleCount: 40),
        ],
        cacheByteCount: 4_000_000
    )

    private static let buildingAgain = RuntimeTypeIndexStatus(
        platforms: [
            .init(platformName: "iphoneos", sdkVersion: nil, phase: .unavailable(.sdkNotInstalled), indexedModuleCount: 0),
            .init(platformName: "macosx", sdkVersion: "27.2-27C5", phase: .building(finishedBatchCount: 3, queuedBatchCount: 4), indexedModuleCount: 48),
        ],
        cacheByteCount: 4_500_000
    )

    private func makeCoordinator(on engine: RuntimeEngine, answering script: StatusScript) -> TypeIndexCoordinator {
        TypeIndexCoordinator(
            engine: engine,
            statusProvider: { script.answer() },
            pollingIntervalNanoseconds: Self.pollingIntervalNanoseconds
        )
    }

    @Test("the coordinator reports building, then ready and unavailable platforms, polls only while building, and refreshes on typeNamesResolved")
    func typeIndexCoordinatorReportsBuildingReadyAndUnavailable() async throws {
        let engine = TestRuntimeEngine.makeUnconnected(engineID: "TypeIndexCoordinatorTests.phases")
        let script = StatusScript(Self.building)
        let coordinator = makeCoordinator(on: engine, answering: script)
        defer { withExtendedLifetime(coordinator) {} }

        // Asked once as it starts.
        try await waitUntil { coordinator.status == Self.building }
        #expect(coordinator.status.isBuilding)
        #expect(try await nextValue(from: coordinator.hasActiveIndexing) == true)

        // Building, it polls, and the next poll brings the batches' end.
        script.status = Self.readyAndUnavailable
        try await waitUntil { coordinator.status == Self.readyAndUnavailable }
        #expect(coordinator.status.isBuilding == false)
        #expect(try await nextValue(from: coordinator.hasActiveIndexing) == false)
        let unavailablePhase = coordinator.status.platforms.first { $0.platformName == "iphoneos" }?.phase
        #expect(unavailablePhase == .unavailable(.sdkNotInstalled))

        // Nothing building: no more polls.
        try await waitUntil { !coordinator.hasWorkUnderWay }
        let requestCountWhenReady = script.requestCount
        try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds * 5)
        #expect(script.requestCount == requestCountWhenReady)

        // A finished batch the engine broadcasts asks again.
        script.status = Self.buildingAgain
        engine.dataChangeSubject.send(.typeNamesResolved(platformName: "macosx"))
        try await waitUntil { coordinator.status == Self.buildingAgain }
        #expect(coordinator.status.isBuilding)

        // Closed, it asks for nothing again, polls included.
        coordinator.close()
        let requestCountWhenClosed = script.requestCount
        script.status = Self.readyAndUnavailable
        engine.dataChangeSubject.send(.typeNamesResolved(platformName: "macosx"))
        try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds * 5)
        #expect(script.requestCount == requestCountWhenClosed)
        #expect(coordinator.status == Self.buildingAgain)
        #expect(!coordinator.hasWorkUnderWay)
    }

    @Test("an engine without a type index answers no platform, and nothing is polled")
    func engineWithoutTypeIndexReportsNothing() async throws {
        let engine = TestRuntimeEngine.makeUnconnected(engineID: "TypeIndexCoordinatorTests.empty")
        let script = StatusScript(.empty)
        let coordinator = makeCoordinator(on: engine, answering: script)
        defer { withExtendedLifetime(coordinator) {} }

        try await waitUntil { script.requestCount == 1 && !coordinator.hasWorkUnderWay }
        try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds * 5)

        #expect(coordinator.status == .empty)
        #expect(script.requestCount == 1)
        #expect(try await nextValue(from: coordinator.hasActiveIndexing) == false)
    }
}

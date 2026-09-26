#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// Opening an image in the sidebar while the launch-time "always index"
/// batches are building it.
///
/// Replays a fresh launch with five "always index" entries — `AppKit`,
/// `Foundation`, `libswiftCore.dylib`, `SwiftUI` and `SwiftUICore`, none of
/// them following dependencies, maximum concurrency 28 — and opens AppKit once
/// its background build is under way. The engine standing in for the app's
/// forwards to a `RuntimeLocalRuntimeServiceHost` over a real XPC connection,
/// as in `RuntimeLocalRuntimeServiceHostTests`: the batches run at utility
/// priority on the app side, and the opening request comes from a
/// user-initiated task through the `objectsWithProgress(in:)` the sidebar calls.
///
/// This is the reproduction behind the proposal
/// draft-background-indexing-yields-to-foreground: before it, opening AppKit
/// this way took 1.63× as long as opening it alone in a Debug build (41 s
/// against 25 s) and 1.26× in Release.
///
/// It is a timing test that indexes five large frameworks, so it runs only
/// when `RUNTIME_VIEWER_PERFORMANCE_TESTS` is set. MachOSwiftSection's caches
/// live as long as the process, so each test needs a process of its own:
///
/// ```
/// RUNTIME_VIEWER_PERFORMANCE_TESTS=1 swift test --skip-build \
///     --filter ForegroundLoadDuringBackgroundIndexingTests/openingWithoutBackgroundIndexing
/// RUNTIME_VIEWER_PERFORMANCE_TESTS=1 FOREGROUND_LOAD_BASELINE_SECONDS=<the baseline's duration> \
///     swift test --skip-build \
///     --filter ForegroundLoadDuringBackgroundIndexingTests/openingDuringAlwaysIndexBatches
/// ```
///
/// `FOREGROUND_LOAD_ALWAYS_INDEX` replaces the list of "always index"
/// identifiers with a comma-separated one. Both tests print their timeline.
@Suite(
    "Opening an image while background indexing builds it",
    .enabled(if: ProcessInfo.processInfo.environment["RUNTIME_VIEWER_PERFORMANCE_TESTS"] != nil)
)
struct ForegroundLoadDuringBackgroundIndexingTests {
    private static let alwaysIndexIdentifiers: [String] = {
        guard let configuredIdentifiers = ProcessInfo.processInfo.environment["FOREGROUND_LOAD_ALWAYS_INDEX"] else {
            return ["AppKit", "Foundation", "libswiftCore.dylib", "SwiftUI", "SwiftUICore"]
        }
        return configuredIdentifiers.split(separator: ",").map { String($0) }
    }()

    private static let openedIdentifier = "AppKit"

    private static let maximumConcurrency = 28

    /// How much longer than on its own opening the image may take while the
    /// batches run.
    ///
    /// Not 1: with Max Concurrent Tasks at 28 the four other images keep
    /// building alongside, which the proposal accepts in exchange for leaving
    /// the setting in charge, and those builds slow any build in the process.
    /// Measured in Debug on an M3 Ultra, the factor was 1.63–1.67 while AppKit
    /// was built a second time and 1.17–1.37 once the request joined the
    /// background build; 1.5 separates the two with room for noise.
    private static let allowedSlowdownFactor = 1.5

    @Test("Opening AppKit with no background indexing (baseline)", .timeLimit(.minutes(30)))
    func openingWithoutBackgroundIndexing() async throws {
        let (host, client) = try await Self.makeConnectedEngines(label: "baseline")
        defer { Task { await client.stop(); await host.stop() } }
        let openedPath = try await Self.resolvedPath(of: Self.openedIdentifier, in: client)

        let start = ContinuousClock.now
        let foregroundLoad = try await Self.open(openedPath, in: client, since: start)

        Self.report("baseline", foregroundLoad: foregroundLoad, timeline: nil)
        #expect(foregroundLoad.objectCount > 0)
    }

    @Test("Opening AppKit while the always-index batches run stays close to opening it alone", .timeLimit(.minutes(30)))
    func openingDuringAlwaysIndexBatches() async throws {
        let baselineSeconds = try #require(
            ProcessInfo.processInfo.environment["FOREGROUND_LOAD_BASELINE_SECONDS"].flatMap { Double($0) },
            "run openingWithoutBackgroundIndexing first and pass its duration in FOREGROUND_LOAD_BASELINE_SECONDS"
        )
        let (host, client) = try await Self.makeConnectedEngines(label: "contended")
        defer { Task { await client.stop(); await host.stop() } }
        var alwaysIndexPaths: [String] = []
        for identifier in Self.alwaysIndexIdentifiers {
            try await alwaysIndexPaths.append(Self.resolvedPath(of: identifier, in: client))
        }
        let openedPath = try await Self.resolvedPath(of: Self.openedIdentifier, in: client)

        let start = ContinuousClock.now
        let timeline = IndexingTimeline(start: start)
        let manager = await client.backgroundIndexingManager
        let events = manager.events
        let recorder = Task {
            for await event in events {
                await timeline.record(event)
            }
        }
        defer { recorder.cancel() }

        // What the coordinator does at launch for each "always index" entry.
        for (identifier, path) in zip(Self.alwaysIndexIdentifiers, alwaysIndexPaths) {
            _ = await manager.startBatch(
                rootImagePath: path,
                depth: 0,
                maxConcurrency: Self.maximumConcurrency,
                reason: .alwaysIndex(identifier: identifier)
            )
        }

        // The user opens the image a moment after launch, once the background
        // builds are under way — its own, when it is one of the entries.
        let awaitedPath = alwaysIndexPaths.contains(openedPath) ? openedPath : alwaysIndexPaths.first
        if let awaitedPath {
            let backgroundBuildStarted = await pollUntil(timeout: .seconds(60)) {
                await timeline.taskStartedAt(awaitedPath) != nil
            }
            try #require(backgroundBuildStarted, "the background build of \(awaitedPath) never started")
        }
        try await Task.sleep(for: .seconds(1))

        // Selecting an image in the sidebar also asks the indexer to prioritize it.
        Task { await manager.prioritize(imagePath: openedPath) }
        let foregroundLoad = try await Self.open(openedPath, in: client, since: start)

        let everyBatchFinished = await pollUntil(timeout: .seconds(1800)) {
            await timeline.finishedBatchCount == alwaysIndexPaths.count
        }
        let snapshot = await timeline.snapshot()
        Self.report("contended", foregroundLoad: foregroundLoad, timeline: snapshot)

        #expect(foregroundLoad.objectCount > 0)
        #expect(everyBatchFinished, "not every background batch finished")
        let foregroundSeconds = Self.secondsValue(foregroundLoad.finishedAt - foregroundLoad.openedAt)
        print("[ForegroundLoad] contended: foreground took \(String(format: "%.1f", foregroundSeconds))s, \(String(format: "%.2f", foregroundSeconds / baselineSeconds))x the baseline of \(String(format: "%.1f", baselineSeconds))s")
        #expect(
            foregroundSeconds <= baselineSeconds * Self.allowedSlowdownFactor,
            "opening \(Self.openedIdentifier) took \(String(format: "%.1f", foregroundSeconds))s while the batches ran, against \(String(format: "%.1f", baselineSeconds))s on its own"
        )
    }
}

// MARK: - Support

extension ForegroundLoadDuringBackgroundIndexingTests {
    private struct PhaseChange: Sendable {
        let phase: String
        let at: Duration
    }

    private struct ForegroundLoad: Sendable {
        let openedAt: Duration
        let finishedAt: Duration
        let objectCount: Int
        let phaseChanges: [PhaseChange]
    }

    private static func makeConnectedEngines(label: String) async throws -> (host: RuntimeLocalRuntimeServiceHost, client: RuntimeEngine) {
        let serviceEngine = RuntimeEngine(source: .local, engineID: "foreground-load-test.\(label).host")
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
        try await host.start()
        host.activate()
        let client = RuntimeEngine(source: .local, engineID: "foreground-load-test.\(label).client")
        try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
        let hostImageList = await host.engine.imageList
        let received = await pollUntil(timeout: .seconds(30)) {
            await client.imageList == hostImageList
        }
        try #require(received, "the client never received the service's image list")
        return (host, client)
    }

    /// Resolves an "always index" identifier the way the coordinator does.
    private static func resolvedPath(of identifier: String, in client: RuntimeEngine) async throws -> String {
        let imageList = await client.imageList
        return try #require(
            imageList.first { ($0 as NSString).lastPathComponent == identifier },
            "\(identifier) is not in the image list"
        )
    }

    /// Opens `path` the way the sidebar does, from a user-initiated task.
    private static func open(_ path: String, in client: RuntimeEngine, since start: ContinuousClock.Instant) async throws -> ForegroundLoad {
        let openedAt = ContinuousClock.now - start
        return try await Task(priority: .userInitiated) {
            var phaseChanges: [PhaseChange] = []
            var objectCount = 0
            let stream = await client.objectsWithProgress(in: path)
            for try await event in stream {
                switch event {
                case .progress(let progress):
                    if phaseChanges.last?.phase != progress.phase.rawValue {
                        phaseChanges.append(PhaseChange(phase: progress.phase.rawValue, at: ContinuousClock.now - start))
                    }
                case .completed(let objects):
                    objectCount = objects.count
                }
            }
            return ForegroundLoad(
                openedAt: openedAt,
                finishedAt: ContinuousClock.now - start,
                objectCount: objectCount,
                phaseChanges: phaseChanges
            )
        }.value
    }

    private static func report(_ label: String, foregroundLoad: ForegroundLoad, timeline: IndexingTimeline.Snapshot?) {
        print("[ForegroundLoad] \(label): opened at \(seconds(foregroundLoad.openedAt)), finished at \(seconds(foregroundLoad.finishedAt)), \(foregroundLoad.objectCount) objects")
        for phaseChange in foregroundLoad.phaseChanges {
            print("[ForegroundLoad]   foreground phase \(phaseChange.phase) from \(seconds(phaseChange.at))")
        }
        guard let timeline else { return }
        for (path, startedAt) in timeline.taskStartedAt.sorted(by: { $0.value < $1.value }) {
            let finishedAt = timeline.taskFinishedAt[path].map { seconds($0) } ?? "-"
            let result = timeline.taskResults[path].map { "\($0)" } ?? "-"
            print("[ForegroundLoad]   background \((path as NSString).lastPathComponent): started \(seconds(startedAt)), finished \(finishedAt), \(result)")
        }
        for (path, finishedAt) in timeline.batchFinishedAt.sorted(by: { $0.value < $1.value }) {
            print("[ForegroundLoad]   batch \((path as NSString).lastPathComponent) finished \(seconds(finishedAt))")
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1fs", secondsValue(duration))
    }

    private static func secondsValue(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Wall-clock record of the background indexer's events, relative to one start.
private actor IndexingTimeline {
    struct Snapshot: Sendable {
        var taskStartedAt: [String: Duration] = [:]
        var taskFinishedAt: [String: Duration] = [:]
        var taskResults: [String: RuntimeIndexingTaskState] = [:]
        var batchFinishedAt: [String: Duration] = [:]
    }

    private let start: ContinuousClock.Instant

    private var current = Snapshot()

    init(start: ContinuousClock.Instant) {
        self.start = start
    }

    func record(_ event: RuntimeIndexingEvent) {
        let elapsed = ContinuousClock.now - start
        switch event {
        case .taskStarted(_, let path):
            current.taskStartedAt[path] = elapsed
        case .taskFinished(_, let path, let result):
            current.taskFinishedAt[path] = elapsed
            current.taskResults[path] = result
        case .batchFinished(let batch),
             .batchCancelled(let batch):
            current.batchFinishedAt[batch.rootImagePath] = elapsed
        case .batchStarted,
             .taskPrioritized:
            break
        }
    }

    func taskStartedAt(_ path: String) -> Duration? {
        current.taskStartedAt[path]
    }

    var finishedBatchCount: Int {
        current.batchFinishedAt.count
    }

    func snapshot() -> Snapshot {
        current
    }
}

private func pollUntil(
    timeout: Duration,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

#endif

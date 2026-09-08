import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerCommandLineInterface

/// Cancelling a command has to reach the work itself. Two hops can swallow it:
/// the host cancels a request only when a cancel frame arrives — never when the
/// connection simply goes away — and the export runs in a Task of its own,
/// which inherits no cancellation and passes none on through `.value`.
@Suite("Cancellation reaches the work", .serialized, .timeLimit(.minutes(2)))
struct CancellationTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    /// Polls because the cancellation travels through the socket, the host
    /// actor and the executor before the resolver sees it.
    private func becomesTrue(within seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("A closed connection cancels the command it left in flight")
    func closedConnectionCancelsItsRequest() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let resolver = CancellationObservingSourceResolver()
        let host = try await InProcessHost.start(paths: paths, resolver: resolver)

        let client = makeClient(paths: paths)
        try await client.connect()
        let sendTask = Task { try? await client.send(.listTypes(ListTypesCommand())) }

        #expect(await becomesTrue(within: 3) { await resolver.hasStarted }, "The host never started the command")

        // The client vanishes without sending a cancel frame: Ctrl-C, a crash,
        // or a `--timeout` that fired before the frame went out.
        await client.disconnect()

        #expect(
            await becomesTrue(within: 3) { await resolver.didObserveCancellation },
            "The host kept the command running after the connection that asked for it closed"
        )

        sendTask.cancel()
        await host.stop()
    }

    @Test("A cancelled export stops writing instead of finishing the image")
    func cancelledExportStopsWriting() async throws {
        // Its own engine: the shared one indexes libobjc, which is small enough
        // to finish before a cancellation could be told apart from completion.
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeViewerCommandLineTests.exportCancellation")
        try await engine.connect()
        _ = try await engine.objects(in: Self.foundationPath)

        let outputDirectory = URL(fileURLWithPath: "/tmp/rvcli-export-cancel-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let executor = CommandExecutor(sourceResolver: LocalSourceResolver(engine: engine))
        let command = Command.export(ExportCommand(
            image: Self.foundationPath,
            outputDirectory: outputDirectory.path,
            objcLayout: .directory,
            swiftLayout: .directory,
            includeMetadata: false
        ))

        let trigger = CancelOnFirstExportedObject()
        let exportTask = Task<CommandResult, any Error> {
            try await executor.execute(command) { progress in
                if progress.phase == "exporting" {
                    await trigger.fire()
                }
            }
        }
        await trigger.register(exportTask)

        var failure: CommandFailure?
        do {
            _ = try await exportTask.value
        } catch let error as CommandFailure {
            failure = error
        }

        // Before the fix this is `.exportFailed` — "finished without a result" —
        // because the export ran to completion while nothing was listening.
        #expect(failure?.code == .cancelled, "Expected a cancelled export, got \(String(describing: failure))")

        let writtenFileCount = Self.fileCount(in: outputDirectory)
        #expect(
            writtenFileCount < 200,
            "The export wrote \(writtenFileCount) files after being cancelled; it should have stopped near the first object"
        )
    }

    private static func fileCount(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }
}

/// Reports whether the work was started and whether it was cancelled, so a test
/// can tell "the host stopped it" from "the host waited for it".
private actor CancellationObservingSourceResolver: SourceResolving {
    private(set) var hasStarted = false
    private(set) var didObserveCancellation = false

    func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine {
        hasStarted = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        didObserveCancellation = true
        throw CommandFailure(code: .cancelled, message: "The stub resolver was cancelled.")
    }

    func loadedImagePaths() async -> [String] { [] }

    func shutdown() async {}
}

/// Cancels the export as soon as its first object is reported. The progress
/// frame can arrive before the task is registered, so the trigger remembers.
private actor CancelOnFirstExportedObject {
    private var task: Task<CommandResult, any Error>?
    private var shouldCancel = false

    func register(_ task: Task<CommandResult, any Error>) {
        self.task = task
        if shouldCancel {
            task.cancel()
        }
    }

    func fire() {
        shouldCancel = true
        task?.cancel()
    }
}

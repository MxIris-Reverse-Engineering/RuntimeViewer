#if os(macOS)

import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerAppCore

/// What the content pane's placeholder says while it has no object: the hint
/// to select one, or — while the offline service is still reading the
/// window's file — that the file is being read. The file is served by a
/// `RuntimeOfflineServiceHost` over an anonymous listener that accepts nothing
/// until the test starts it, which holds the read under way.
@Suite("Content placeholder", .serialized)
@MainActor
struct ContentPlaceholderViewModelTests {
    @Test("An engine that reads no file only ever asks for a selection")
    func engineReadingNoFileAsksForASelection() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "content-placeholder-test.local")
        let recorder = PlaceholderRecorder()
        let subscription = ContentPlaceholderViewModel.placeholders(for: engine).subscribeOnNext { placeholder in
            recorder.record(placeholder)
        }
        defer { subscription.dispose() }

        #expect(await pollUntil { recorder.placeholders == [.noSelection] })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(recorder.placeholders == [.noSelection])
    }

    @Test("A file still being read says so, and asks for a selection once the file is read")
    func fileBeingReadSaysSo() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeOfflineServiceHost(connection: listener)
        let file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        let engine = RuntimeEngine(source: file.source, engineID: "content-placeholder-test.file")
        let recorder = PlaceholderRecorder()
        let subscription = ContentPlaceholderViewModel.placeholders(for: engine).subscribeOnNext { placeholder in
            recorder.record(placeholder)
        }
        defer {
            subscription.dispose()
            Task { await host.stop() }
        }
        let credential = RuntimeConnectionCredential.xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeOfflineService.launchPayload(for: file))))
        let connecting = Task { try await engine.connect(credential: credential) }

        #expect(await pollUntil { recorder.placeholders.last == .readingFile(named: file.displayName) })

        host.activate()
        try await connecting.value

        #expect(await pollUntil { recorder.placeholders.last == .noSelection })
        #expect(recorder.placeholders.contains(.readingFile(named: file.displayName)))
    }
}

private final class PlaceholderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPlaceholders: [ContentPlaceholderViewModel.Placeholder] = []

    var placeholders: [ContentPlaceholderViewModel.Placeholder] {
        lock.withLock { storedPlaceholders }
    }

    func record(_ placeholder: ContentPlaceholderViewModel.Placeholder) {
        lock.withLock { storedPlaceholders.append(placeholder) }
    }
}

private func pollUntil(
    timeout: Duration = .seconds(30),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

#endif

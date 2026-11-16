import Foundation
import Testing

@testable import RuntimeViewerSettings

/// When the Theme editor writes a preset it edits back to the settings
/// (`DraftWriteBack`): once per pause rather than once per change, at once
/// when the user commits, and — the edit the user made last — still when the
/// editor goes away before the pause is over.
@Suite("DraftWriteBack")
@MainActor
struct DraftWriteBackTests {
    @MainActor
    private final class Writes {
        var values: [String] = []
    }

    private static let delay: Duration = .milliseconds(100)

    /// Long enough for a write scheduled `delay` ago to have run.
    private static let settleTime: Duration = .milliseconds(400)

    @Test("changes made in quick succession are written once, as the last of them")
    func changesAreWrittenOncePerPause() async throws {
        let writes = Writes()
        let writeBack = DraftWriteBack<String>(delay: Self.delay)

        writeBack.draftDidChange(to: "A") { writes.values.append($0) }
        writeBack.draftDidChange(to: "AB") { writes.values.append($0) }
        writeBack.draftDidChange(to: "ABC") { writes.values.append($0) }
        #expect(writes.values.isEmpty)

        try await Task.sleep(for: Self.settleTime)
        #expect(writes.values == ["ABC"])
    }

    @Test("a change still waiting when the editor goes away is written then")
    func waitingChangeIsWrittenWhenTheEditorGoesAway() async throws {
        let writes = Writes()
        let writeBack = DraftWriteBack<String>(delay: Self.delay)

        writeBack.draftDidChange(to: "edited") { writes.values.append($0) }
        writeBack.editorDidDisappear()

        #expect(writes.values == ["edited"])
        try await Task.sleep(for: Self.settleTime)
        #expect(writes.values == ["edited"])
    }

    @Test("committing writes the value at once and drops the change still waiting")
    func commitWritesAtOnce() async throws {
        let writes = Writes()
        let writeBack = DraftWriteBack<String>(delay: Self.delay)

        writeBack.draftDidChange(to: "draft") { writes.values.append($0) }
        writeBack.commit("committed") { writes.values.append($0) }
        #expect(writes.values == ["committed"])

        writeBack.editorDidDisappear()
        try await Task.sleep(for: Self.settleTime)
        #expect(writes.values == ["committed"])
    }

    @Test("the editor going away with nothing waiting writes nothing")
    func nothingWaitingWritesNothing() async throws {
        let writes = Writes()
        let writeBack = DraftWriteBack<String>(delay: Self.delay)

        writeBack.draftDidChange(to: "written") { writes.values.append($0) }
        try await Task.sleep(for: Self.settleTime)
        writeBack.editorDidDisappear()

        #expect(writes.values == ["written"])
    }
}

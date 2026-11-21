import Foundation
import OSLog
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What Export Logs writes, now shared by both apps (proposal
/// `window-model-on-ios`): this process's entries under a RuntimeViewer
/// subsystem, one formatted line each, and nobody else's.
@Suite("Application logs")
struct ApplicationLogsTests {
    @Test("lists this process's RuntimeViewer entries since a date, one formatted line each")
    func listsThisProcessesEntries() async throws {
        let since = Date()
        let marker = "ApplicationLogsTests \(UUID().uuidString)"
        // A fixture: an entry under a RuntimeViewer subsystem, and one under another.
        Logger(subsystem: "com.JH.RuntimeViewer.Tests", category: "ApplicationLogs").notice("\(marker, privacy: .public)")
        Logger(subsystem: "com.example.Unrelated", category: "ApplicationLogs").notice("\(marker, privacy: .public) unrelated")

        var text = ""
        let arrived = try await pollUntil(timeout: .seconds(10)) {
            text = try await ApplicationLogs.formattedEntries(since: since)
            return text.contains(marker)
        }
        #expect(arrived, "the entry never showed up in the log store")

        let line = try #require(text.split(separator: "\n").first { $0.contains(marker) })
        let linePrefix = try Regex(#"\[\d\d:\d\d:\d\d\.\d\d\d\] \[com\.JH\.RuntimeViewer\.Tests/ApplicationLogs\] "#)
        #expect(line.prefixMatch(of: linePrefix) != nil, "unexpected line: \(line)")
        #expect(!text.contains("\(marker) unrelated"), "an entry under another subsystem was written")
    }
}

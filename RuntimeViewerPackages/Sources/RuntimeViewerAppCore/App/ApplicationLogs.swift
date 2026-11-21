import Foundation
import OSLog

/// What Export Logs writes: the entries this process logged under a
/// RuntimeViewer subsystem. Collecting them is the same on every platform;
/// asking where to save them and showing the file is each front end's.
public enum ApplicationLogs {
    /// The entries this process logged under a RuntimeViewer subsystem since
    /// `date`, oldest first, one line each:
    /// `[HH:mm:ss.SSS] [subsystem/category] message`. Reading the log store is
    /// slow, and runs off the caller's actor.
    public static func formattedEntries(since date: Date) async throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: date))
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        var content = ""
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog, logEntry.subsystem.contains("RuntimeViewer") else { continue }
            content.append("[\(timeFormatter.string(from: logEntry.date))] [\(logEntry.subsystem)/\(logEntry.category)] \(logEntry.composedMessage)\n")
        }
        return content
    }
}

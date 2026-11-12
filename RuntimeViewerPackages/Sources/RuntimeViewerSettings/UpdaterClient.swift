import Foundation
import Observation

/// Observable state and actions surfaced to the Updates settings page.
///
/// The app target registers a live implementation that bridges Sparkle; in
/// previews / unit tests the default instance provides safe no-op values so
/// the Settings UI renders without the app layer present.
@Observable
@MainActor
public final class UpdaterClient {
    public private(set) var currentVersionDisplay: String
    public private(set) var lastCheckDate: Date?
    public private(set) var isSessionInProgress: Bool
    public private(set) var lastCheckError: Error?

    public var checkForUpdates: @MainActor () -> Void

    public init(
        currentVersionDisplay: String = UpdaterClient.defaultVersionDisplay(),
        lastCheckDate: Date? = nil,
        isSessionInProgress: Bool = false,
        lastCheckError: Error? = nil,
        checkForUpdates: @escaping @MainActor () -> Void = {}
    ) {
        self.currentVersionDisplay = currentVersionDisplay
        self.lastCheckDate = lastCheckDate
        self.isSessionInProgress = isSessionInProgress
        self.lastCheckError = lastCheckError
        self.checkForUpdates = checkForUpdates
    }

    public func setCurrentVersionDisplay(_ value: String) {
        currentVersionDisplay = value
    }

    public func setLastCheckDate(_ value: Date?) {
        lastCheckDate = value
    }

    public func setIsSessionInProgress(_ value: Bool) {
        isSessionInProgress = value
    }

    public func setLastCheckError(_ value: Error?) {
        lastCheckError = value
    }

    // Nonisolated so it can be invoked from default-argument context (which
    // evaluates outside the class's MainActor isolation).
    public nonisolated static func defaultVersionDisplay() -> String {
        let informationDictionary = Bundle.main.infoDictionary
        let shortVersionString = informationDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = informationDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(shortVersionString) (\(build))"
    }

    /// What the Updates page shows for the last check: `date` relative to the page's clock `now`.
    ///
    /// The page's clock only ticks every 30 seconds, so a check that finished since the last tick is later
    /// than `now`. A check is never in the future: such a date reads as "now", not "in 8 seconds".
    public nonisolated static func lastCheckDisplay(
        for date: Date?,
        relativeTo now: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }
}

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
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

#if os(macOS)

import AppKit
import Foundation
import FoundationToolbox
import HelperCommunication
import HelperClient
import ApplicationsServiceInterface
import RuntimeViewerCommunication
import Dependencies
import DependenciesMacros
import ServiceManagement

/// Thin wrapper that routes Catalyst-launch RPCs through the shared lib `HelperClient`
/// owned by `HelperServiceManager`. Connection lifecycle / version reconcile lives in
/// `HelperServiceManager`; this type is kept only so the `@Dependency` injection point
/// `runtimeHelperClient` and its narrow business surface (`launchMacCatalystHelper`)
/// stay stable for callers.
@Loggable
public final class RuntimeHelperClient: @unchecked Sendable {
    public enum Error: LocalizedError {
        case message(String)
        case catalystHelperNotFound

        public var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            case .catalystHelperNotFound:
                return "This process has no RuntimeViewer application bundle to launch the Mac Catalyst helper from."
            }
        }
    }

    fileprivate static let shared = RuntimeHelperClient()

    @Dependency(\.helperServiceManager) private var helperServiceManager

    @Dependency(\.runtimeResourceLocator) private var runtimeResourceLocator

    private init() {
        Task { @MainActor in
            observeStatusChange()
        }
    }

    @MainActor
    private func observeStatusChange() {
        withObservationTracking {
            _ = helperServiceManager.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if helperServiceManager.status == .enabled {
                    await reconnect()
                }
                observeStatusChange()
            }
        }
    }

    /// Invalidates the current connection and re-establishes it through
    /// `HelperServiceManager`'s shared lib `HelperClient`.
    public func reconnect() async {
        await helperServiceManager.reconnect()
    }

    /// Launches a fresh instance of the Mac Catalyst helper through the daemon.
    ///
    /// Any instance already running from the same bundle is ended first. The
    /// daemon opens the helper with `createsNewApplicationInstance = false`,
    /// so with an instance still alive the request returns *that* process,
    /// which registered against whatever daemon and endpoint existed when it
    /// started and never handshakes again — the app then owns a Catalyst
    /// engine nothing will ever answer.
    public func launchMacCatalystHelper() async throws {
        guard let helperURL = runtimeResourceLocator.catalystHelperApplicationURL else {
            throw Error.catalystHelperNotFound
        }
        await terminateMacCatalystHelper(at: helperURL)
        let callerPID = ProcessInfo.processInfo.processIdentifier
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: OpenApplicationRequest(url: helperURL, callerPID: callerPID)
        )
    }

    /// Ends every running instance of this bundle's Mac Catalyst helper and
    /// waits, bounded by ``helperTerminationTimeout``, for them to exit.
    ///
    /// Matched by bundle URL, not bundle identifier: the Debug, Debug-arm64e
    /// and Release apps each carry their own helper under the same identifier,
    /// and one app must not kill another's.
    public func terminateMacCatalystHelper() async {
        guard let helperURL = runtimeResourceLocator.catalystHelperApplicationURL else { return }
        await terminateMacCatalystHelper(at: helperURL)
    }

    /// How long ``terminateMacCatalystHelper()`` waits for a helper to exit
    /// before giving up on it. A helper that ignores `terminate()` is
    /// force-terminated at the halfway mark.
    static let helperTerminationTimeout: TimeInterval = 3

    private func terminateMacCatalystHelper(at helperURL: URL) async {
        let helperPath = helperURL.standardizedFileURL.path
        let runningHelpers = NSWorkspace.shared.runningApplications.filter { application in
            application.bundleURL?.standardizedFileURL.path == helperPath && !application.isTerminated
        }
        guard !runningHelpers.isEmpty else { return }
        #log(.info, "Ending \(runningHelpers.count, privacy: .public) running Mac Catalyst helper instance(s) before launching a fresh one")
        for helper in runningHelpers {
            helper.terminate()
        }
        let pollInterval: TimeInterval = 0.1
        let deadline = Date().addingTimeInterval(Self.helperTerminationTimeout)
        let forceDeadline = Date().addingTimeInterval(Self.helperTerminationTimeout / 2)
        var didForce = false
        while runningHelpers.contains(where: { !$0.isTerminated }), Date() < deadline {
            if !didForce, Date() >= forceDeadline {
                didForce = true
                for helper in runningHelpers where !helper.isTerminated {
                    helper.forceTerminate()
                }
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        if runningHelpers.contains(where: { !$0.isTerminated }) {
            #log(.error, "A Mac Catalyst helper instance did not exit within \(Self.helperTerminationTimeout, privacy: .public)s; the launch request may return it instead of a fresh instance")
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: RuntimeHelperClient.shared)
    public var runtimeHelperClient: RuntimeHelperClient
}

#endif

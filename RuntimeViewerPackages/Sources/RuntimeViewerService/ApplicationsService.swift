#if os(macOS)

import AppKit
import FoundationToolbox
import HelperCommunication
import HelperService
import RuntimeViewerCommunication

/// Handles `OpenApplicationRequest` and terminates child apps when their caller PID exits.
@Loggable
public actor ApplicationsService: HelperService {
    public enum Error: Swift.Error {
        case deallocated
    }

    private var launchedApplicationsByCallerPID: [pid_t: [NSRunningApplication]] = [:]

    private var workspaceMonitorTask: Task<Void, Never>?

    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: OpenApplicationRequest) -> OpenApplicationRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.openApplication(request: request)
        }
        startWorkspaceMonitor()
    }

    public func run() async throws {}

    // MARK: - Handlers

    private func openApplication(request: OpenApplicationRequest) async throws -> OpenApplicationRequest.Response {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.activates = false
        let launchedApp = try await NSWorkspace.shared.openApplication(at: request.url, configuration: configuration)
        launchedApplicationsByCallerPID[request.callerPID, default: []].append(launchedApp)
        return .empty
    }

    // MARK: - Caller-PID lifecycle

    private func startWorkspaceMonitor() {
        workspaceMonitorTask?.cancel()
        workspaceMonitorTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didTerminateApplicationNotification)
            for await notification in notifications {
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { continue }
                await self.handleApplicationTermination(pid: app.processIdentifier)
            }
        }
    }

    private func handleApplicationTermination(pid: pid_t) {
        guard let launchedApps = launchedApplicationsByCallerPID.removeValue(forKey: pid) else { return }
        for launchedApp in launchedApps where !launchedApp.isTerminated {
            launchedApp.terminate()
        }
    }
}

#endif

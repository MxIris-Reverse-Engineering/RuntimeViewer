#if os(macOS)

import AppKit
import FoundationToolbox
import SwiftyXPC
import MachInjector
import RuntimeViewerCommunication

/// Privileged helper daemon running as a Mach service.
///
/// Handles:
/// - XPC endpoint brokering between Host app and Mac Catalyst helper
/// - Code injection via `MachInjector`
/// - Privileged file operations (installing `RuntimeViewerServer.framework`)
/// - Injected endpoint registry for Host app reconnection after restart
///   (stores endpoints keyed by PID, monitors PIDs via DispatchSource for auto-cleanup)
/// - Process lifecycle tracking (terminates child apps when caller exits)
@Loggable
public final class RuntimeViewerService {
    private let listener: SwiftyXPC.XPCListener

    private var launchedApplicationsByCallerPID: [Int32: [NSRunningApplication]] = [:]

    private var endpointByIdentifier: [String: SwiftyXPC.XPCEndpoint] = [:]

    /// Registered endpoints from injected (non-sandboxed) apps, keyed by PID.
    /// Separate from `endpointByIdentifier` which handles 1-to-1 XPC brokering.
    private var injectedEndpointsByPID: [pid_t: InjectedEndpointInfo] = [:]

    /// Dispatch sources monitoring injected process PIDs for auto-cleanup on exit.
    private var processMonitorSources: [pid_t: any DispatchSourceProcess] = [:]

    private init() throws {
        self.listener = try .init(type: .machService(name: RuntimeViewerMachServiceName), codeSigningRequirement: nil)
        listener.setMessageHandler(handler: registerEndpoint)
        listener.setMessageHandler(handler: fetchEndpoint)
        listener.setMessageHandler(handler: openApplication)
        listener.setMessageHandler(handler: ping)
        listener.setMessageHandler(handler: injectApplication)
        listener.setMessageHandler(handler: fileOperation)
        listener.setMessageHandler(handler: registerInjectedEndpoint)
        listener.setMessageHandler(handler: fetchAllInjectedEndpoints)
        listener.setMessageHandler(handler: removeInjectedEndpoint)
        listener.activate()
    }

    private func ping(_ connection: XPCConnection, request: PingRequest) async throws -> PingRequest.Response {
        return .empty
    }

    private func fetchEndpoint(_ connection: XPCConnection, request: FetchEndpointRequest) async throws -> FetchEndpointRequest.Response {
        guard let endpoint = endpointByIdentifier[request.identifier] else {
            throw XPCError.unknown("No endpoint available")
        }
        return .init(endpoint: endpoint)
    }

    private func registerEndpoint(_ connection: XPCConnection, request: RegisterEndpointRequest) async throws -> RegisterEndpointRequest.Response {
        endpointByIdentifier[request.identifier] = request.endpoint
        return .empty
    }

    private func openApplication(_ connection: XPCConnection, request: OpenApplicationRequest) async throws -> OpenApplicationRequest.Response {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.activates = false
        let launchedApp = try await NSWorkspace.shared.openApplication(at: request.url, configuration: configuration)
        launchedApplicationsByCallerPID[request.callerPID, default: []].append(launchedApp)
        return .empty
    }

    private func fileOperation(_ connection: XPCConnection, request: FileOperationRequest) async throws -> FileOperationRequest.Response {
        let fileManager = FileManager.default
        switch request.operation {
        case let .createDirectory(url, isIntermediateDirectories):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: isIntermediateDirectories)
        case let .remove(url: url):
            try fileManager.removeItem(at: url)
        case let .move(from: from, to: to):
            try fileManager.moveItem(at: from, to: to)
        case let .copy(from: from, to: to):
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            try fileManager.copyItem(at: from, to: to)
        case let .write(url: url, data: data):
            try data.write(to: url)
        }
        return .empty
    }

    private func injectApplication(_ connection: XPCConnection, request: InjectApplicationRequest) async throws -> InjectApplicationRequest.Response {
        try await MainActor.run {
            try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
        }
        return .empty
    }

    // MARK: - Injected Endpoint Registry

    private func registerInjectedEndpoint(_ connection: XPCConnection, request: RegisterInjectedEndpointRequest) async throws -> RegisterInjectedEndpointRequest.Response {
        let injectedEndpointInfo = InjectedEndpointInfo(
            pid: request.pid,
            appName: request.appName,
            bundleIdentifier: request.bundleIdentifier,
            endpoint: request.endpoint
        )
        injectedEndpointsByPID[request.pid] = injectedEndpointInfo
        startMonitoringProcess(pid: request.pid)
        #log(.info, "Registered injected endpoint for PID \(request.pid) (\(request.appName, privacy: .public))")
        return .empty
    }

    private func fetchAllInjectedEndpoints(_ connection: XPCConnection, request: FetchAllInjectedEndpointsRequest) async throws -> FetchAllInjectedEndpointsRequest.Response {
        let endpoints = Array(injectedEndpointsByPID.values)
        #log(.info, "Fetching all injected endpoints, count: \(endpoints.count)")
        return .init(endpoints: endpoints)
    }

    private func removeInjectedEndpoint(_ connection: XPCConnection, request: RemoveInjectedEndpointRequest) async throws -> RemoveInjectedEndpointRequest.Response {
        removeInjectedEndpointEntry(pid: request.pid)
        return .empty
    }

    private func startMonitoringProcess(pid: pid_t) {
        processMonitorSources[pid]?.cancel()

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            #log(.info, "Monitored process \(pid) exited, removing injected endpoint")
            removeInjectedEndpointEntry(pid: pid)
        }
        processMonitorSources[pid] = source
        source.resume()
    }

    private func removeInjectedEndpointEntry(pid: pid_t) {
        injectedEndpointsByPID.removeValue(forKey: pid)
        processMonitorSources[pid]?.cancel()
        processMonitorSources.removeValue(forKey: pid)
        #log(.info, "Removed injected endpoint for PID \(pid)")
    }

    public static func main() throws {
        try autoreleasepool {
            let service = try RuntimeViewerService()
            Task {
                let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didTerminateApplicationNotification)

                for await notification in notifications {
                    do {
                        try Task.checkCancellation()

                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { continue }

                        let pid = app.processIdentifier
                        guard let launchedApps = service.launchedApplicationsByCallerPID.removeValue(forKey: pid) else { continue }

                        for launchedApp in launchedApps {
                            if !launchedApp.isTerminated {
                                launchedApp.terminate()
                            }
                        }
                    } catch {
                        #log(.error,"\(error, privacy: .public)")
                    }
                }
            }
            RunLoop.current.run()
        }
    }
}

#endif

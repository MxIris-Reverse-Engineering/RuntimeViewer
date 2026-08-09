import Foundation
import FoundationToolbox
import Dependencies
import DependenciesMacros
import SwiftNavigation
import RuntimeViewerSettings
import SwiftMCP

public enum MCPServerState: Equatable, Sendable {
    case disabled
    case stopped
    case running(port: UInt16)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var port: UInt16? {
        if case .running(let port) = self { return port }
        return nil
    }
}

@Loggable
@MainActor
public final class MCPService {
    fileprivate static let shared = MCPService()

    @Dependency(\.settings)
    private var settings

    public private(set) var serverState: MCPServerState = .stopped {
        didSet {
            guard oldValue != serverState else { return }
            onStateChange?(serverState)
        }
    }

    public var onStateChange: ((MCPServerState) -> Void)?

    private(set) var transport: HTTPSSETransport?

    private var startTask: Task<Void, Never>?

    private var observeToken: ObserveToken?

    private var previousMCPEnabled: Bool?

    private var previousMCPUsesFixedPort: Bool?

    private var previousMCPFixedPort: UInt16?

    private var documentProvider: MCPBridgeDocumentProvider?

    private var restartTask: Task<Void, Never>?

    private let portFilePath: String

    /// True while this instance owns the on-disk port file. A failed-bind
    /// instance never wrote one, so its `stop()` must not delete the file
    /// the winning instance's clients rely on (proposal 0006).
    private var hasWrittenPortFile = false

    private convenience init() {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDirectory = appSupportURL.appendingPathComponent("RuntimeViewer")
        do {
            try FileManager.default.createDirectory(at: runtimeViewerDirectory, withIntermediateDirectories: true)
        } catch {
            #log(.error,"Failed to create app support directory: \(error)")
        }
        self.init(portFilePath: runtimeViewerDirectory.appendingPathComponent(Settings.MCP.portFileName).path)
    }

    /// Internal seam so tests can point the port file at a scratch location.
    init(portFilePath: String) {
        self.portFilePath = portFilePath
    }

    isolated deinit {
        stop()
    }

    public func start(for documentProvider: some MCPBridgeDocumentProvider) {
        self.documentProvider = documentProvider

        // Initialize previous values before observing to avoid a spurious restart
        let currentMCP = settings.mcp
        previousMCPEnabled = currentMCP.isEnabled
        previousMCPUsesFixedPort = currentMCP.useFixedPort
        previousMCPFixedPort = currentMCP.fixedPort

        guard currentMCP.isEnabled else {
            serverState = .disabled
            observe()
            return
        }
        startTask = Task {
            let mcpSettings = settings.mcp
            let port: UInt16 = mcpSettings.useFixedPort ? mcpSettings.fixedPort : 0
            await startTransport(on: port, for: documentProvider)
            observe()
        }
    }

    /// Binds the MCP transport on `port` (`0` = ephemeral). Split from
    /// `start(for:)` so tests can drive the bind path without going through
    /// settings.
    ///
    /// `transport.start()` returns only after the listener is bound, so
    /// reaching the success path IS the bind confirmation — no fixed sleep,
    /// and the port file is written only for a listener that actually
    /// exists. On failure the transport is torn down: its NIO event-loop
    /// group is created eagerly at init, so a lost bind race (e.g. the
    /// fixed port is held by another RuntimeViewer instance) must not keep
    /// `System.coreCount` event loops and their threads resident, and the
    /// state must report `.stopped` truthfully (proposal 0006).
    func startTransport(on port: UInt16, for documentProvider: some MCPBridgeDocumentProvider) async {
        let mcpServer = MCPBridgeServer(documentProvider: documentProvider)
        let boundTransport = HTTPSSETransport(server: mcpServer, host: "127.0.0.1", port: Int(port))
        transport = boundTransport
        do {
            try await boundTransport.start()
            guard !Task.isCancelled else {
                // stop() ran while the bind was in flight and already set the
                // user-facing state; just release this instance's resources.
                if transport === boundTransport { transport = nil }
                try? await boundTransport.stop()
                return
            }
            let boundPort = UInt16(boundTransport.port)
            writePortFile(port: boundPort)
            #log(.info,"MCP HTTP+SSE server listening on port \(boundPort)")
            serverState = .running(port: boundPort)
        } catch {
            #log(.error,"Failed to start MCP server: \(error)")
            if transport === boundTransport { transport = nil }
            try? await boundTransport.stop()
            if !Task.isCancelled {
                serverState = .stopped
            }
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        restartTask?.cancel()
        restartTask = nil
        if let transport {
            Task.detached {
                try? await transport.stop()
            }
        }
        transport = nil
        let isEnabled = settings.mcp.isEnabled
        serverState = isEnabled ? .stopped : .disabled
        removePortFileIfOwned()
        observeToken?.cancel()
        observeToken = nil
    }

    private func observe() {
        observeToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            let mcpSettings = settings.mcp
            let isMCPEnabled = mcpSettings.isEnabled
            let isUsesFixedPort = mcpSettings.useFixedPort
            let fixedPort = mcpSettings.fixedPort

            let enabledChanged = isMCPEnabled != previousMCPEnabled
            let portChanged = isUsesFixedPort != previousMCPUsesFixedPort || fixedPort != previousMCPFixedPort

            previousMCPEnabled = isMCPEnabled
            previousMCPUsesFixedPort = isUsesFixedPort
            previousMCPFixedPort = fixedPort

            if enabledChanged || portChanged {
                if !isMCPEnabled {
                    serverState = .disabled
                }
                scheduleRestart(enabled: isMCPEnabled)
            }
        }
    }

    private func scheduleRestart(enabled: Bool) {
        restartTask?.cancel()
        restartTask = Task {
            // Debounce: wait for settings to stabilize (e.g. user typing port number)
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if enabled {
                stop()
                if let documentProvider {
                    start(for: documentProvider)
                }
            } else {
                stop()
                observe()
            }
        }
    }

    // MARK: - Port File

    private func writePortFile(port: UInt16) {
        do {
            try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
            hasWrittenPortFile = true
            #log(.info,"Wrote MCP HTTP+SSE port \(port) to \(self.portFilePath)")
        } catch {
            #log(.error,"Failed to write port file: \(error)")
        }
    }

    private func removePortFileIfOwned() {
        guard hasWrittenPortFile else { return }
        hasWrittenPortFile = false
        do {
            try FileManager.default.removeItem(atPath: portFilePath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already removed, ignore
        } catch {
            #log(.error,"Failed to remove port file: \(error)")
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { MCPService.shared })
    public var mcpService: MCPService
}

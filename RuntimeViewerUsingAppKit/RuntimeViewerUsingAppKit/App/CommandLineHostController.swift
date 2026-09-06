import Dependencies
import DependenciesMacros
import Foundation
import FoundationToolbox
import RuntimeViewerApplication
import RuntimeViewerCommandLineInterface
import RuntimeViewerCore
import RuntimeViewerEngineManagement
import RuntimeViewerHelperClient
import RuntimeViewerSettings

/// Makes the running app the CLI host, so `runtime-viewer-cli` sees every
/// source the app has — attached processes, devices on the network — instead
/// of a second Bonjour client and injector standing next to it.
///
/// On launch it asks a standalone host to leave (the host drains its commands
/// first), then binds the same socket with `kind: .application`. When another
/// app instance is the host already, this one stays out of the way. On quit
/// the socket and record are removed so the next command starts a standalone
/// host again; injected processes are picked back up through the existing
/// reconnection registries.
@Loggable
@MainActor
final class CommandLineHostController {
    fileprivate static let shared = CommandLineHostController()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager
    @Dependency(\.runtimeInjectClient) private var runtimeInjectClient
    @Dependency(\.helperServiceManager) private var helperServiceManager

    private let paths = CommandLineHostPaths.resolveDefault()
    private var server: CommandLineHostServer?
    private var startTask: Task<Void, Never>?

    private init() {}

    /// `applicationDidFinishLaunching`. Takes over asynchronously; the app
    /// does not wait for a standalone host to drain.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { await claimAndServe() }
    }

    /// `applicationWillTerminate`. Cannot await the server actor there, so the
    /// files a client would look at are removed synchronously; the listening
    /// socket closes with the process.
    func stop() {
        startTask?.cancel()
        startTask = nil
        if let server {
            self.server = nil
            Task { await server.stop(reason: .shutdownRequested(.userRequest)) }
        }
        CommandLineHostServer.removeArtifactsSynchronously(at: paths)
    }

    private func claimAndServe() async {
        switch await HostTakeover.claim(paths: paths) {
        case .noHost:
            break
        case .tookOver(let processIdentifier, let exited):
            #log(.info, "Took over the CLI host from process \(processIdentifier, privacy: .public) (exited: \(exited, privacy: .public))")
        case .anotherApplicationHost(let processIdentifier):
            #log(.info, "Another RuntimeViewer (process \(processIdentifier, privacy: .public)) is the CLI host; this instance does not serve the CLI")
            return
        case .failed(let reason):
            #log(.error, "Could not take over the CLI host: \(reason, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }

        let resolver = EngineManagerSourceResolver.forEngineManager(
            runtimeEngineManager,
            injectClient: runtimeInjectClient,
            helperServiceManager: helperServiceManager,
            applicationBundleURL: Bundle.main.bundleURL
        )
        let executor = CommandExecutor(sourceResolver: resolver, applicationOptionsReader: LiveApplicationOptionsReader())
        let server = CommandLineHostServer(
            configuration: CommandLineHostServer.Configuration(paths: paths, kind: .application, idleTimeout: nil),
            executor: executor
        )
        do {
            try await server.start()
            self.server = server
            // `self.` because the macro evaluates the interpolation in a closure.
            #log(.info, "Serving the CLI at \(self.paths.socketURL.path, privacy: .public)")
        } catch {
            #log(.error, "Could not start the CLI host: \(String(describing: error), privacy: .public)")
        }
    }
}

/// `--options app` answered from the running app's live settings, the same
/// merge the content pane uses, instead of from the files a standalone host
/// has to read.
private struct LiveApplicationOptionsReader: ApplicationOptionsReading {
    func readGenerationOptions() async -> RuntimeObjectInterface.GenerationOptions {
        await MainActor.run {
            @Dependency(\.appDefaults) var appDefaults
            @Dependency(\.settings) var settings
            var options = appDefaults.options
            options.transformer = settings.transformer
            return options
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { CommandLineHostController.shared })
    var commandLineHostController: CommandLineHostController
}

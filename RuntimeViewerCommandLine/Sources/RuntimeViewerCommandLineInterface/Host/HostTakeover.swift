import Foundation

/// The app's side of "the app is the host while it runs": before binding its
/// own listener it asks a standalone host to leave, and steps aside when
/// another app instance already is the host.
public enum HostTakeover {
    public enum Outcome: Sendable, Equatable {
        /// Nothing answered on the socket; bind at once.
        case noHost
        /// A standalone host was asked to leave. `exited` is false when it
        /// was still around after the timeout and the signal; binding may
        /// then fail on the instance lock.
        case tookOver(processIdentifier: Int32, exited: Bool)
        /// Another RuntimeViewer app is the host already; do not bind.
        case anotherApplicationHost(processIdentifier: Int32)
        /// Something answered that could be neither retired nor identified.
        case failed(String)
    }

    /// Clears the way for an application host on `paths`.
    public static func claim(paths: CommandLineHostPaths, timeout: TimeInterval = 5) async -> Outcome {
        let client = CommandLineHostClient(
            configuration: CommandLineHostClient.Configuration(paths: paths, allowsSpawning: false),
            launcher: nil
        )
        let welcome: Welcome
        do {
            welcome = try await client.connect()
        } catch let error as CommandLineHostClient.ClientError {
            switch error {
            case .hostUnreachable, .hostDidNotStart, .connectionLost, .notConnected:
                return .noHost
            case .unsupportedProtocolVersion(_, let hostKind):
                // The handshake is all that could be exchanged; identify the
                // host by its record instead.
                let recorded = HostRecord.read(from: paths.recordURL)?.processIdentifier
                switch hostKind {
                case .application:
                    return .anotherApplicationHost(processIdentifier: recorded ?? 0)
                case .standalone:
                    guard let recorded else {
                        return .failed("an outdated standalone host answers on \(paths.socketURL.path) but left no \(paths.recordURL.lastPathComponent) to identify it")
                    }
                    let outcome = await HostRetirement.terminate(processIdentifier: recorded, paths: paths, timeout: timeout)
                    return .tookOver(processIdentifier: recorded, exited: outcome.exited)
                }
            }
        } catch {
            return .failed(String(describing: error))
        }

        switch welcome.hostKind {
        case .application:
            await client.disconnect()
            return .anotherApplicationHost(processIdentifier: welcome.processIdentifier)
        case .standalone:
            let outcome = await HostRetirement.retire(client, welcome: welcome, paths: paths, reason: .applicationTakeover, timeout: timeout)
            return .tookOver(processIdentifier: welcome.processIdentifier, exited: outcome.exited)
        }
    }
}

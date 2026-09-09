#if os(macOS)
import Foundation

/// Which responsibilities a ``RuntimeEngineManager`` takes on.
///
/// Fixed at construction rather than toggled at run time: advertising and
/// sharing acquire peers the moment they start, so switching them off later
/// would mean a disconnect-cleanup story nothing needs yet. Peer discovery is
/// not a switch — every configuration browses for peers.
public struct RuntimeEngineManagerConfiguration: Sendable, Hashable {
    /// Start the Bonjour server so peers can discover this process.
    public var advertisesOverBonjour: Bool

    /// Wrap every local engine in a `RuntimeEngineProxyServer` and publish
    /// descriptors to peers, so they can mirror what this process reaches.
    public var sharesEnginesWithPeers: Bool

    /// Bring up `.local` and the Mac Catalyst client engine on start.
    public var launchesSystemEngines: Bool

    /// Reconnect previously injected processes: XPC endpoints from the helper
    /// daemon's registry, socket endpoints from the record file on disk.
    public var reconnectsInjectedEngines: Bool

    public init(
        advertisesOverBonjour: Bool,
        sharesEnginesWithPeers: Bool,
        launchesSystemEngines: Bool,
        reconnectsInjectedEngines: Bool
    ) {
        self.advertisesOverBonjour = advertisesOverBonjour
        self.sharesEnginesWithPeers = sharesEnginesWithPeers
        self.launchesSystemEngines = launchesSystemEngines
        self.reconnectsInjectedEngines = reconnectsInjectedEngines
    }

    /// Everything on: what the app has always done.
    public static let application = Self(
        advertisesOverBonjour: true,
        sharesEnginesWithPeers: true,
        launchesSystemEngines: true,
        reconnectsInjectedEngines: true
    )

    /// A process with no window of its own. It browses for peers and picks up
    /// injected processes, but neither advertises nor shares: peers should see
    /// one RuntimeViewer per machine, and that is the app's role, not a second
    /// Bonjour client standing next to it.
    public static let headlessHost = Self(
        advertisesOverBonjour: false,
        sharesEnginesWithPeers: false,
        launchesSystemEngines: true,
        reconnectsInjectedEngines: true
    )
}

extension RuntimeEngineManagerConfiguration {
    /// One thing `RuntimeEngineManager.init` brings up.
    enum StartupStep: Hashable, CaseIterable {
        case bonjourServer
        case bonjourBrowser
        case systemEngines
        case injectedEngineReconnection
        case engineSharing
    }

    /// The steps this configuration selects, in the order `init` schedules
    /// them. The Bonjour server precedes the browser so the local TXT record is
    /// registered before the browser can discover it; system engines precede
    /// injected reconnection because they always have.
    var startupSteps: [StartupStep] {
        var steps: [StartupStep] = []
        if advertisesOverBonjour {
            steps.append(.bonjourServer)
        }
        steps.append(.bonjourBrowser)
        if launchesSystemEngines {
            steps.append(.systemEngines)
        }
        if reconnectsInjectedEngines {
            steps.append(.injectedEngineReconnection)
        }
        if sharesEnginesWithPeers {
            steps.append(.engineSharing)
        }
        return steps
    }
}
#endif

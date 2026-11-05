import Foundation
import Network
public import FoundationToolbox

@Loggable
public final class RuntimeNetworkBrowser {
    private let browser: NWBrowser

    /// One host-visible effect of a browse change.
    ///
    /// `start`'s handler produces these through the `events(for…)` functions
    /// below and only then touches its callbacks, so the decision — which
    /// browse changes the host hears about at all — is a pure function the
    /// tests can hold still without an `NWBrowser`.
    enum Event: Equatable {
        case added(RuntimeNetworkEndpoint)
        case removed(RuntimeNetworkEndpoint)
    }

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        self.browser = NWBrowser(for: .bonjourWithTXTRecord(type: RuntimeNetworkBonjour.type, domain: nil), using: parameters)
    }

    public func start(
        onAdded: @escaping (RuntimeNetworkEndpoint) -> Void,
        onRemoved: @escaping (RuntimeNetworkEndpoint) -> Void
    ) {
        #log(.info, "Starting Bonjour browser for service type: \(RuntimeNetworkBonjour.type, privacy: .public)")
        browser.stateUpdateHandler = { newState in
            #log(.info, "Browser state changed: \(String(describing: newState), privacy: .public)")
        }
        browser.browseResultsChangedHandler = { results, changes in
            #log(.info, "Browse results changed: \(results.count, privacy: .public) result(s), \(changes.count, privacy: .public) change(s)")
            for change in changes {
                let events: [Event]
                switch change {
                case .added(let result):
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    let discovered = RuntimeNetworkEndpoint(name: name, result: result)
                    #log(.info, "Discovered new endpoint: \(name, privacy: .public), key: \(discovered.uniqueKey, privacy: .public), process: \(discovered.processName ?? "nil", privacy: .public), deviceID: \(discovered.deviceID ?? "nil", privacy: .public), instanceID: \(discovered.instanceID ?? "nil", privacy: .public), hostName: \(discovered.hostName ?? "nil", privacy: .public)")
                    events = Self.events(forAdded: discovered)
                    if events.isEmpty {
                        #log(.info, "Holding endpoint until its TXT record arrives: \(name, privacy: .public)")
                    }
                case .removed(let result):
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    let removed = RuntimeNetworkEndpoint(name: name, result: result)
                    #log(.info, "Endpoint removed: \(name, privacy: .public), key: \(removed.uniqueKey, privacy: .public)")
                    events = Self.events(forRemoved: removed)
                case .changed(let oldResult, let newResult, _):
                    guard case .service(let oldName, _, _, _) = oldResult.endpoint,
                          case .service(let newName, _, _, _) = newResult.endpoint
                    else { continue }
                    let previous = RuntimeNetworkEndpoint(name: oldName, result: oldResult)
                    let current = RuntimeNetworkEndpoint(name: newName, result: newResult)
                    events = Self.events(forChangeFrom: previous, to: current)
                    if events.contains(where: \.isAdded) {
                        #log(.info, "Endpoint replaced in place: \(previous.uniqueKey, privacy: .public) -> \(current.uniqueKey, privacy: .public)")
                    } else if events.isEmpty {
                        #log(.debug, "Endpoint metadata changed but identity held: \(current.uniqueKey, privacy: .public)")
                    } else {
                        #log(.info, "Endpoint replaced, but its successor carries no identity yet: \(previous.uniqueKey, privacy: .public), holding until its TXT record arrives")
                    }
                default:
                    continue
                }
                for event in events {
                    switch event {
                    case .added(let endpoint): onAdded(endpoint)
                    case .removed(let endpoint): onRemoved(endpoint)
                    }
                }
            }
        }
        browser.start(queue: .main)
    }

    // MARK: - Browse change decisions

    /// An addition is reported only once the endpoint carries the advertising
    /// installation's instance identity.
    ///
    /// mDNS answers the TXT record separately from the service record, so a
    /// browse result can surface *before* its TXT arrives — on first discovery,
    /// or mid-flap while a peer's listener re-registers. Such a result has
    /// every identity field `nil`, and every downstream check then degrades to
    /// the service name: the manager's self-filter compares `instanceID`
    /// against its own and passes (`nil` matches nothing), so a host connects
    /// to *its own advertisement* and shows it as a foreign device named after
    /// the local machine; grouping keys the ghost's section on the name; and
    /// the origin chain records the name, which no peer's cycle detection
    /// recognizes, so the ghost survives being mirrored across hosts. Holding
    /// the result here closes all of that at the single entry point.
    ///
    /// A held endpoint is not lost. When its TXT record arrives, `NWBrowser`
    /// reports a `.changed` whose `uniqueKey` moves from the name to
    /// `{deviceID}-{pid}` — `metadataChange` classifies that as
    /// `.replacesEndpoint` and ``events(forChangeFrom:to:)`` re-enters this
    /// gate with the identified endpoint.
    ///
    /// The hold is safe to apply unconditionally: `rv-instance-id` has been in
    /// every advertisement since v2.0.0-RC.5. The only release that ever
    /// advertised without a TXT record is v2.0.0-RC.4, so an endpoint with no
    /// identity is a transient race, not a peer class.
    static func events(forAdded discovered: RuntimeNetworkEndpoint) -> [Event] {
        guard discovered.instanceID != nil else { return [] }
        return [.added(discovered)]
    }

    static func events(forRemoved endpoint: RuntimeNetworkEndpoint) -> [Event] {
        [.removed(endpoint)]
    }

    /// Acting on `.changed` at all exists because the advertised name is
    /// launch-stable on purpose: a relaunched peer keeps its service instance
    /// name and moves only its TXT record, which `NWBrowser` reports as a
    /// change to an existing result rather than a removal plus an addition.
    /// Ignoring it would leave the host attached to a dead pid and blind to
    /// the live one.
    ///
    /// The replacement is reported as removal-then-arrival because that is
    /// what it is. Note what the host actually does with each today:
    /// `onRemoved` is deliberately inert — a listener cancelled after
    /// accepting a connection de-registers the service, so acting on a removal
    /// would drop a peer that is merely flapping — and the reconnect is driven
    /// entirely by `onAdded`. The entry for the dead process ages out when the
    /// heartbeat expires, the behaviour already accepted in PR106X.2. Passing
    /// `previous` still matters: if removal ever grows teeth, it must bite the
    /// old key.
    ///
    /// The arrival half re-enters ``events(forAdded:)``, so a successor that
    /// has not published its TXT record yet is held exactly like a fresh
    /// discovery would be — this is also the path that releases a held
    /// endpoint once its TXT record arrives.
    static func events(forChangeFrom previous: RuntimeNetworkEndpoint, to current: RuntimeNetworkEndpoint) -> [Event] {
        switch RuntimeNetworkEndpoint.metadataChange(from: previous, to: current) {
        case .sameEndpoint:
            return []
        case .replacesEndpoint:
            return [.removed(previous)] + events(forAdded: current)
        }
    }
}

extension RuntimeNetworkBrowser.Event {
    fileprivate var isAdded: Bool {
        if case .added = self { return true }
        return false
    }
}

import Foundation
import Network
public import FoundationToolbox

@Loggable
public class RuntimeNetworkBrowser {
    private let browser: NWBrowser

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
                switch change {
                case .added(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let discovered = RuntimeNetworkEndpoint(name: name, result: result)
                        #log(.info, "Discovered new endpoint: \(name, privacy: .public), key: \(discovered.uniqueKey, privacy: .public), process: \(discovered.processName ?? "nil", privacy: .public), deviceID: \(discovered.deviceID ?? "nil", privacy: .public), instanceID: \(discovered.instanceID ?? "nil", privacy: .public), hostName: \(discovered.hostName ?? "nil", privacy: .public)")
                        onAdded(discovered)
                    }
                case .removed(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let removed = RuntimeNetworkEndpoint(name: name, result: result)
                        #log(.info, "Endpoint removed: \(name, privacy: .public), key: \(removed.uniqueKey, privacy: .public)")
                        onRemoved(removed)
                    }
                case .changed(let oldResult, let newResult, _):
                    // Dropping this case used to be harmless: while the service
                    // name carried the pid, a relaunched peer arrived under a
                    // new *name* and so as .removed + .added. The name is now
                    // launch-stable on purpose, so a relaunch moves only the
                    // TXT record — which arrives here, not there. Ignoring it
                    // leaves the host attached to a dead pid and blind to the
                    // live one.
                    guard case .service(let oldName, _, _, _) = oldResult.endpoint,
                          case .service(let newName, _, _, _) = newResult.endpoint
                    else { break }
                    let previous = RuntimeNetworkEndpoint(name: oldName, result: oldResult)
                    let current = RuntimeNetworkEndpoint(name: newName, result: newResult)
                    switch RuntimeNetworkEndpoint.metadataChange(from: previous, to: current) {
                    case .replacesEndpoint:
                        #log(.info, "Endpoint replaced in place: \(previous.uniqueKey, privacy: .public) -> \(current.uniqueKey, privacy: .public)")
                        // Reported as removal-then-arrival because that is what
                        // it is. Note what the host actually does with each
                        // today: `onRemoved` is deliberately inert — a listener
                        // cancelled after accepting a connection de-registers
                        // the service, so acting on a removal would drop a peer
                        // that is merely flapping — and the reconnect is driven
                        // entirely by `onAdded`. So this restores the host's
                        // ability to *reach* the new process; the entry for the
                        // dead one goes away on its own when the heartbeat
                        // expires, which is the behaviour already accepted in
                        // PR106X.2. Passing `previous` still matters: if
                        // removal ever grows teeth, it must bite the old key.
                        onRemoved(previous)
                        onAdded(current)
                    case .sameEndpoint:
                        #log(.debug, "Endpoint metadata changed but identity held: \(current.uniqueKey, privacy: .public)")
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}

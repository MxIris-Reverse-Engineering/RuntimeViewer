import Foundation
public import FoundationToolbox
import Network

public enum RuntimeNetworkError: Error {
    case notConnected
    case invalidPort
    case receiveFailed
}

public struct RuntimeNetworkRequestError: Error, Codable {
    public let message: String
}

struct RuntimeRequestData: Codable {
    let identifier: String

    let data: Data

    init(identifier: String, data: Data) {
        self.identifier = identifier
        self.data = data
    }

    init<Value: Codable>(identifier: String, value: Value) throws {
        self.identifier = identifier
        self.data = try JSONEncoder().encode(value)
    }

    init<Request: RuntimeRequest>(request: Request) throws {
        self.identifier = Request.identifier
        self.data = try JSONEncoder().encode(request)
    }
}

public enum RuntimeNetworkBonjour {
    public static let type = "_runtimeviewer._tcp"
    public static let instanceIDKey = "rv-instance-id"

    /// Unique identifier for this app process, used to filter out self-discovery in Bonjour browsing.
    public static let localInstanceID = UUID().uuidString

    static func makeService(name: String) -> NWListener.Service {
        var txtRecord = NWTXTRecord()
        txtRecord[instanceIDKey] = localInstanceID
        return NWListener.Service(name: name, type: type, txtRecord: txtRecord)
    }

    static func instanceID(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let txtRecord) = metadata else { return nil }
        return txtRecord[instanceIDKey]
    }
}

public struct RuntimeNetworkEndpoint: Sendable, Hashable {
    public let name: String
    public let instanceID: String?

    let endpoint: NWEndpoint

    init(name: String, instanceID: String? = nil, endpoint: NWEndpoint) {
        self.name = name
        self.instanceID = instanceID
        self.endpoint = endpoint
    }

    // Exclude instanceID from equality — it is metadata, not identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(endpoint)
    }
}

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
                        let instanceID = RuntimeNetworkBonjour.instanceID(from: result.metadata)
                        #log(.info, "Discovered new endpoint: \(name, privacy: .public), instanceID: \(instanceID ?? "nil", privacy: .public)")
                        onAdded(.init(name: name, instanceID: instanceID, endpoint: result.endpoint))
                    }
                case .removed(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let instanceID = RuntimeNetworkBonjour.instanceID(from: result.metadata)
                        #log(.info, "Endpoint removed: \(name, privacy: .public)")
                        onRemoved(.init(name: name, instanceID: instanceID, endpoint: result.endpoint))
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}

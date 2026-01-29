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
}

public struct RuntimeNetworkEndpoint: Sendable, Codable, Equatable {
    public let name: String
    
    let endpoint: NWEndpoint
    
    init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
    
    private enum CodableError: Error {
        case unsupported
    }
    
    public init(from decoder: any Decoder) throws {
        throw CodableError.unsupported
    }
    
    public func encode(to encoder: any Encoder) throws {
        throw CodableError.unsupported
    }
}

@Loggable
public class RuntimeNetworkBrowser {
    private let browser: NWBrowser

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        self.browser = NWBrowser(for: .bonjour(type: RuntimeNetworkBonjour.type, domain: nil), using: parameters)
    }

    public func start(handler: @escaping (RuntimeNetworkEndpoint) -> Void) {
        browser.stateUpdateHandler = { newState in
            #log(.info, "browser.stateUpdateHandler \(String(describing: newState), privacy: .public)")
        }
        browser.browseResultsChangedHandler = { results, changes in
            for result in results {
                switch result.endpoint {
                case .service(let name, _, _, _):
                    handler(.init(name: name, endpoint: result.endpoint))
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}

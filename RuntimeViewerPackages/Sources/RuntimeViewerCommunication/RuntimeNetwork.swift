//
//  RuntimeNetworkError.swift
//  RuntimeViewerPackages
//
//  Created by JH on 2025/3/22.
//

import Foundation
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

public struct RuntimeNetworkEndpoint {
    public let name: String
    let endpoint: NWEndpoint
}

public class RuntimeNetworkBrowser {
    private let browser: NWBrowser

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        self.browser = NWBrowser(for: .bonjour(type: RuntimeNetworkBonjour.type, domain: nil), using: parameters)
    }

    public func start(handler: @escaping (RuntimeNetworkEndpoint) -> Void) {
        browser.stateUpdateHandler = { newState in
            print("browser.stateUpdateHandler \(newState)")
        }
        browser.browseResultsChangedHandler = { results, changes in
            for result in results {
                switch result.endpoint {
                case let .service(name, _, _, _):
                    handler(.init(name: name, endpoint: result.endpoint))
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}

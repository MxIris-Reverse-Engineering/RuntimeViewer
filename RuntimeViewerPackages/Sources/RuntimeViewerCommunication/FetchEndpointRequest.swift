//
//  FetchEndpointRequest.swift
//  RuntimeViewerPackages
//
//  Created by JH on 11/30/24.
//

import Foundation
import SwiftyXPC

public struct FetchEndpointRequest: Codable, RequestType {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchEndpoint"

    public struct Response: ResponseType, Codable {
        public let endpoint: XPCEndpoint

        public init(endpoint: XPCEndpoint) {
            self.endpoint = endpoint
        }
    }

    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

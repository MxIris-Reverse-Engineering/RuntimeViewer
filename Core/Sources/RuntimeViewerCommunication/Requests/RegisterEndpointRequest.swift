//
//  RegisterEndpointRequest.swift
//  RuntimeViewerPackages
//
//  Created by JH on 11/29/24.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import SwiftyXPC

public struct RegisterEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RegisterEndpoint"

    public typealias Response = VoidResponse

    public let identifier: String

    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(identifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.identifier = identifier
        self.endpoint = endpoint
    }
}

#endif

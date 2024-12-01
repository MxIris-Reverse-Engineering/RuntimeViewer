//
//  PingRequest.swift
//  RuntimeViewerPackages
//
//  Created by JH on 11/30/24.
//

import Foundation

public struct PingRequest: Codable, RequestType {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.RuntimeViewerService.Ping"

    public init() {}
}

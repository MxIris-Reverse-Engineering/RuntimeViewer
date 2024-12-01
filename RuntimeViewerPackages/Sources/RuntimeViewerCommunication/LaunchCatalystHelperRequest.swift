//
//  LaunchCatalystHelperRequest.swift
//  RuntimeViewerPackages
//
//  Created by JH on 11/30/24.
//

import Foundation

public struct LaunchCatalystHelperRequest: Codable, RequestType {
    public static let identifier: String = "com.JH.RuntimeViewerService.LaunchCatalystHelper"

    public typealias Response = VoidResponse

    public let helperURL: URL

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }
}

//
//  RuntimeViewerCatalystHelperPlugin.swift
//  RuntimeViewerCatalystHelperPlugin
//
//  Created by JH on 2024/6/27.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerService

class RuntimeViewerCatalystHelperPlugin {
    let runtimeListingsSender = RuntimeListings(source: .macCatalyst(isSender: true))

    init() {
        _ = runtimeListingsSender
    }
}

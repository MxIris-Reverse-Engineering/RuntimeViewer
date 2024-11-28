//
//  RuntimeViewerCatalystHelperPlugin.swift
//  RuntimeViewerCatalystHelperPlugin
//
//  Created by JH on 2024/6/27.
//

import Foundation
import RuntimeViewerCore

class RuntimeViewerCatalystHelperPlugin {
    let runtimeListingsServer = RuntimeEngine(source: .remote(name: "MacCatalyst", identifier: .macCatalyst, role: .server))

    init() {
        _ = runtimeListingsServer
    }
}

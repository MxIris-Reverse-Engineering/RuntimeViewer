//
//  ViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import Foundation
import RuntimeViewerArchitectures


open class ViewModel<Route: Routable>: NSObject {
    public let appServices: AppServices
    public unowned let router: any Router<Route>
    public init(appServices: AppServices, router: any Router<Route>) {
        self.appServices = appServices
        self.router = router
    }
}

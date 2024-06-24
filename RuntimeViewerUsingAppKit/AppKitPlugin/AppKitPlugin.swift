//
//  AppKitPlugin.swift
//  AppKitPlugin
//
//  Created by JH on 2024/6/24.
//

import Foundation

@objc(AppKitPlugin)
protocol AppKitPlugin: NSObjectProtocol {
    init()
    func launch()
}

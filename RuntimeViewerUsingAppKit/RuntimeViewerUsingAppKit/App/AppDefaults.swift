//
//  AppDefaults.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import AppKit
import RxDefaultsPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures

class AppDefaults {
    static let shared = AppDefaults()

    @UserDefault(key: "isInitialSetupSplitView", defaultValue: true)
    var isInitialSetupSplitView: Bool

    @UserDefault(key: "generationOptions", defaultValue: .init())
//    @Observed
    var options: CDGenerationOptions
    
    static subscript<Value>(keyPath: ReferenceWritableKeyPath<AppDefaults, Value>) -> Value {
        set {
            shared[keyPath: keyPath] = newValue
        }
        get {
            shared[keyPath: keyPath]
        }
    }

    static subscript<Value>(keyPath: KeyPath<AppDefaults, Value>) -> Value {
        shared[keyPath: keyPath]
    }
}

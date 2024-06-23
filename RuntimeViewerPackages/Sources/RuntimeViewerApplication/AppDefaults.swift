//
//  AppDefaults.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import Foundation
import RxDefaultsPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class AppDefaults {
    public static let shared = AppDefaults()

    @UserDefault(key: "isInitialSetupSplitView", defaultValue: true)
    public var isInitialSetupSplitView: Bool

    @UserDefault(key: "generationOptions", defaultValue: .init())
    ///    @Observed
    public var options: CDGenerationOptions

    public static subscript<Value>(keyPath: ReferenceWritableKeyPath<AppDefaults, Value>) -> Value {
        set {
            shared[keyPath: keyPath] = newValue
        }
        get {
            shared[keyPath: keyPath]
        }
    }

    public static subscript<Value>(keyPath: KeyPath<AppDefaults, Value>) -> Value {
        shared[keyPath: keyPath]
    }
}

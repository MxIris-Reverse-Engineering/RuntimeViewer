import Foundation
import RuntimeViewerUI
import RuntimeViewerSettings
import SwiftUI
import Dependencies

@propertyWrapper
struct AppSettings<Value>: DynamicProperty {
    private let keyPath: ReferenceWritableKeyPath<RuntimeViewerSettings.Settings, Value>
    
    @Dependency(\.settings)
    private var settings
    
    init(_ keyPath: ReferenceWritableKeyPath<RuntimeViewerSettings.Settings, Value>) {
        self.keyPath = keyPath
    }

    var wrappedValue: Value {
        get {
            settings[keyPath: keyPath]
        }
        nonmutating set {
            settings[keyPath: keyPath] = newValue
        }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

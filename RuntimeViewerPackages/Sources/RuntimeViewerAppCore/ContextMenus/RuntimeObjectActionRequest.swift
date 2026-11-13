import Foundation
import RuntimeViewerCore

/// One command chosen on one object, as a view reports it to its view model,
/// which passes it to `ViewModel.perform(_:on:)`.
public struct RuntimeObjectActionRequest: Hashable, Sendable {
    public let action: RuntimeObjectAction

    public let runtimeObject: RuntimeObject

    public init(action: RuntimeObjectAction, runtimeObject: RuntimeObject) {
        self.action = action
        self.runtimeObject = runtimeObject
    }
}

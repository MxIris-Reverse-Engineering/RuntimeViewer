/// The other face of a class that both the Objective-C and the Swift lists
/// show — what `RuntimeEngine.counterpart(for:)` jumps to from an object.
public enum RuntimeObjectCounterpartKind: Hashable, Sendable {
    /// From an Objective-C class that is a Swift class bridged out: that
    /// Swift class.
    case swiftClass

    /// From an `@objc @implementation` class: the Swift `extension` holding
    /// its bodies.
    case swiftImplementation

    /// From a Swift class registered with the Objective-C runtime, or from an
    /// `@objc @implementation` extension: the Objective-C class.
    case objcClass
}

extension RuntimeObject {
    /// Which face `RuntimeEngine.counterpart(for:)` would answer with, decided
    /// from the object's kind and marks alone — so a UI can offer and title
    /// the jump without asking the engine. `nil` when the object has no other
    /// face.
    ///
    /// A mark promises a face, not that the jump succeeds: an
    /// `@objc(CustomName)` class is marked `isSwiftClass` like any bridged
    /// class, but its runtime name is no mangling, so the engine finds nothing.
    public var counterpartKind: RuntimeObjectCounterpartKind? {
        switch kind {
        case .objc(.type(.class)):
            if properties.contains(.isSwiftClass) {
                return .swiftClass
            }
            if properties.contains(.isObjCImplementation) {
                return .swiftImplementation
            }
            return nil
        case .swift(.type(.class)):
            return properties.contains(.isObjCClass) ? .objcClass : nil
        case .swift(.extension):
            return properties.contains(.isObjCImplementation) ? .objcClass : nil
        default:
            return nil
        }
    }
}

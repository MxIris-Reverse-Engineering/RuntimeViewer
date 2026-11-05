/// The other face of a class or protocol that both the Objective-C and the
/// Swift lists show — what `RuntimeEngine.counterpart(for:)` jumps to from an
/// object.
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

    /// From an Objective-C protocol defined in Swift: its `@objc` protocol on
    /// the Swift side — in the image that declares it, which for the copy an
    /// image holds of another module's protocol is another image.
    case swiftProtocol

    /// From an `@objc` protocol on the Swift side: its Objective-C protocol.
    case objcProtocol
}

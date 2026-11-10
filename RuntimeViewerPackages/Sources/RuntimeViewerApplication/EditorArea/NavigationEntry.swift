import Foundation
import RuntimeViewerCore

/// One step of a tab's history: an object, and the language its interface is shown in.
///
/// `interfaceLanguage` is `nil` for the object's own language and `.swift` for an Objective-C
/// class, category or protocol shown as Swift imports it (Generated Interface). Both decide whether
/// two entries are the same step — the object by identity (`RuntimeObject.==`) — so showing an
/// object's Swift form is a step of its own, and Back returns to its header.
public struct NavigationEntry: Hashable, Sendable {
    public let object: RuntimeObject

    public let interfaceLanguage: RuntimeInterfaceLanguage?

    public init(object: RuntimeObject, interfaceLanguage: RuntimeInterfaceLanguage? = nil) {
        self.object = object
        self.interfaceLanguage = interfaceLanguage
    }

    /// Whether the entry shows an Objective-C object as Swift imports it.
    public var showsGeneratedInterface: Bool {
        interfaceLanguage == .swift && object.hasGeneratedInterface
    }

    /// The entry the Generated Interface command switches this one to: the object as Swift imports
    /// it, or back in its own language when it is shown so already; `nil` for an object that has no
    /// Generated Interface.
    public var togglingGeneratedInterface: NavigationEntry? {
        guard object.hasGeneratedInterface else { return nil }
        return NavigationEntry(object: object, interfaceLanguage: showsGeneratedInterface ? nil : .swift)
    }

    /// The language a link opens its target in from an entry shown in `language`: an Objective-C
    /// target reached from a Generated Interface opens as Swift imports it too, as Xcode's
    /// Generated Interface jumps do; anything else in its own.
    public static func interfaceLanguage(forLinkTo target: RuntimeObject, from language: RuntimeInterfaceLanguage?) -> RuntimeInterfaceLanguage? {
        language == .swift && target.hasGeneratedInterface ? .swift : nil
    }
}

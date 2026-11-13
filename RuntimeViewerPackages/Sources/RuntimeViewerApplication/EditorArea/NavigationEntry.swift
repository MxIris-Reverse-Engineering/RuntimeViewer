import Foundation
import RuntimeViewerCore

/// One step of a tab's history: an object and the language its interface is shown in, or an image
/// shown before any of its objects — what choosing an image in an editor pane's jump bar shows
/// (proposal `editor-jump-bar`).
///
/// For an object, `interfaceLanguage` is `nil` for the object's own language and `.swift` for an
/// Objective-C class, category or protocol shown as Swift imports it (Generated Interface). Both
/// decide whether two entries are the same step — the object by identity (`RuntimeObject.==`) — so
/// showing an object's Swift form is a step of its own, and Back returns to its header. Two image
/// entries are the same step when they name the same image path.
public struct NavigationEntry: Hashable, Sendable {
    /// What an entry shows.
    public enum Content: Hashable, Sendable {
        /// An object, in `interfaceLanguage`: `nil` for its own language.
        case object(RuntimeObject, interfaceLanguage: RuntimeInterfaceLanguage?)

        /// An image, by the path its image tree node gives (`RuntimeImageNode.path`), before any of
        /// its objects is shown.
        case image(path: String)
    }

    public let content: Content

    public init(object: RuntimeObject, interfaceLanguage: RuntimeInterfaceLanguage? = nil) {
        self.content = .object(object, interfaceLanguage: interfaceLanguage)
    }

    public init(imagePath: String) {
        self.content = .image(path: imagePath)
    }

    /// The object the entry shows; `nil` for an image.
    public var object: RuntimeObject? {
        guard case .object(let object, _) = content else { return nil }
        return object
    }

    /// The language the entry's object is shown in: `nil` for its own, and for an image.
    public var interfaceLanguage: RuntimeInterfaceLanguage? {
        guard case .object(_, let interfaceLanguage) = content else { return nil }
        return interfaceLanguage
    }

    /// The path of the image the entry shows; `nil` for an object.
    public var imagePath: String? {
        guard case .image(let path) = content else { return nil }
        return path
    }

    /// What the entry is called on a tab and in a history menu: the object's display name, or the
    /// image's file name.
    public var displayName: String {
        switch content {
        case .object(let object, _):
            object.displayName
        case .image(let path):
            Self.imageName(ofImageAt: path)
        }
    }

    /// The file name of the image at `imagePath`, which is what the image tree names it.
    public static func imageName(ofImageAt imagePath: String) -> String {
        (imagePath as NSString).lastPathComponent
    }

    /// Whether the entry shows an Objective-C object as Swift imports it.
    public var showsGeneratedInterface: Bool {
        guard case .object(let object, let interfaceLanguage) = content else { return false }
        return interfaceLanguage == .swift && object.hasGeneratedInterface
    }

    /// The entry the Generated Interface command switches this one to: the object as Swift imports
    /// it, or back in its own language when it is shown so already; `nil` for an object that has no
    /// Generated Interface, and for an image.
    public var togglingGeneratedInterface: NavigationEntry? {
        guard let object, object.hasGeneratedInterface else { return nil }
        return NavigationEntry(object: object, interfaceLanguage: showsGeneratedInterface ? nil : .swift)
    }

    /// The language a link opens its target in from an entry shown in `language`: an Objective-C
    /// target reached from a Generated Interface opens as Swift imports it too, as Xcode's
    /// Generated Interface jumps do; anything else in its own.
    public static func interfaceLanguage(forLinkTo target: RuntimeObject, from language: RuntimeInterfaceLanguage?) -> RuntimeInterfaceLanguage? {
        language == .swift && target.hasGeneratedInterface ? .swift : nil
    }
}

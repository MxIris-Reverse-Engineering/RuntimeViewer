import Foundation

/// What the engine asks an image's C++ section.
protocol RuntimeCPlusPlusSectioning: Actor {
    nonisolated var imagePath: String { get }

    /// The image's C++ classes and namespaces, nested ones as children.
    func allObjects() -> [RuntimeObject]

    /// The class or namespace named `qualifiedName` — the global namespace's
    /// object too — anywhere in the tree; `nil` when the image has none.
    func object(named qualifiedName: String) -> RuntimeObject?

    /// The mangled type name of a base of one of the image's classes, by the
    /// base's qualified name: how a jump to a base in another image starts.
    func mangledTypeName(ofBaseNamed qualifiedName: String) -> String?

    /// `object` printed as a pseudo-header (`CPlusPlusInterfacePrinter`).
    func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) throws -> RuntimeObjectInterface

    /// The primary base of the class named `qualifiedName`: the first direct
    /// base that is not virtual and sits at offset zero. `nil` for a class
    /// without one, and for anything that is not a class with run-time type
    /// information.
    func primaryBase(ofClassNamed qualifiedName: String) -> RuntimeCPlusPlusBaseReference?

    /// The classes of the image deriving directly from the class `object`
    /// names.
    func derivedClasses(of object: RuntimeObject) -> [RuntimeObject]
}

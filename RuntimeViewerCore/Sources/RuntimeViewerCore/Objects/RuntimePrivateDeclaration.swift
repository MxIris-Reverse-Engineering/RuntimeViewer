import Foundation

/// A `private` or `fileprivate` declaration a Swift name reads, as MachOSwiftSection reads it off
/// the demangled name (`DemanglingNode.privateDeclarations`).
///
/// Swift gives every such declaration a private discriminator, so that two of them with the same
/// name in different files stay distinct. The discriminator is `_` followed by 32 uppercase
/// hexadecimal digits: the MD5 of the module's name followed by the source file's name
/// (`SourceFile::getPrivateDiscriminator` in the Swift compiler's `lib/AST/Module.cpp`).
/// `RuntimeEngine.privateDeclarationSourceFiles(forDiscriminators:inImage:)` recovers that file
/// name.
public struct RuntimePrivateDeclaration: Codable, Hashable, Sendable {
    /// The declaration's own name: `EnabledKey`; `init` or `subscript` for a private initializer or
    /// subscript, whose mangled name carries none. `nil` only for a name of a shape MachOSwiftSection
    /// does not expect.
    public let name: String?

    /// The discriminator, leading underscore included.
    public let discriminator: String

    public init(name: String?, discriminator: String) {
        self.name = name
        self.discriminator = discriminator
    }
}

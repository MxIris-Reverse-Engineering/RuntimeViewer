import Foundation

/// A `private` or `fileprivate` declaration in a Swift name, taken from a `privateDeclName` node
/// of the demangled name: the node's first child is the discriminator, its second the
/// declaration's name.
///
/// Swift gives every such declaration a private discriminator, so that two of them with the same
/// name in different files stay distinct. The discriminator is `_` followed by 32 uppercase
/// hexadecimal digits: the MD5 of the module's name followed by the source file's name
/// (`SourceFile::getPrivateDiscriminator` in the Swift compiler's `lib/AST/Module.cpp`).
/// `RuntimePrivateDiscriminatorSourceFiles` recovers that file name.
public struct RuntimePrivateDeclaration: Codable, Hashable, Sendable {
    /// The declaration's own name, `EnabledKey`. `nil` when the node has no second child.
    public let name: String?

    /// The discriminator, leading underscore included.
    public let discriminator: String

    public init(name: String?, discriminator: String) {
        self.name = name
        self.discriminator = discriminator
    }
}

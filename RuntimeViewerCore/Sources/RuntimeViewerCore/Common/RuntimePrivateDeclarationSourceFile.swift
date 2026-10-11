import Foundation

/// The source file a private discriminator was derived from, as the engine recovers it
/// (`RuntimeEngine.privateDeclarationSourceFiles(forDiscriminators:inImage:)`): the discriminator
/// is `MD5(module name + file name)`, so a candidate file name whose digest matches is a certain
/// identification. The search itself is MachOSwiftSection's (`PrivateDiscriminatorSourceFileIndex`).
public struct RuntimePrivateDeclarationSourceFile: Codable, Hashable, Sendable {
    /// The file's name, `Enabled.swift`.
    public let fileName: String

    /// The module name that went into the digest: a framework's own name (`SwiftUICore`), which is
    /// not always the module its types are printed under (`SwiftUI`).
    public let moduleName: String

    /// Whether the discriminator belongs to the file the compiler synthesizes for `fileName`.
    public let isSynthesized: Bool

    public init(fileName: String, moduleName: String, isSynthesized: Bool) {
        self.fileName = fileName
        self.moduleName = moduleName
        self.isSynthesized = isSynthesized
    }
}

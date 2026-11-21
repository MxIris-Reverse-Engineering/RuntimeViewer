import Foundation

/// The per-image C++ sections of an engine.
///
/// Unlike the Objective-C and Swift sections, a C++ section is no part of an
/// image being indexed: it is built the first time something asks for an
/// image's C++ objects (`ObjectsInImageCommand.includesCPlusPlusObjects`),
/// and background indexing, the Find corpus and `isImageIndexed` never look
/// at it.
protocol RuntimeCPlusPlusSectionProviding: Actor {
    associatedtype Section: RuntimeCPlusPlusSectioning

    func existingSection(for imagePath: String) -> Section?

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

    /// The section of the image that exports the typeinfo of the type
    /// `mangledTypeName` mangles to (`N3TST6CellIDE`) — `nil` when the
    /// engine's catalog finds none, as for a type whose typeinfo every image
    /// keeps a hidden copy of.
    func section(definingClassWithMangledTypeName mangledTypeName: String) async throws -> Section?

    func removeAllSections()
}

extension RuntimeCPlusPlusSectionProviding {
    func section(for imagePath: String) async throws -> (isExisted: Bool, section: Section) {
        try await section(for: imagePath, progressContinuation: nil)
    }
}

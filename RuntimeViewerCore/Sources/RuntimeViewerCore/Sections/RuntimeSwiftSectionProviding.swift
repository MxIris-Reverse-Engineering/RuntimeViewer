import Foundation

/// The per-image Swift sections of an engine, and the cross-image tables
/// built as they register.
protocol RuntimeSwiftSectionProviding: Actor {
    associatedtype Section: RuntimeSwiftSectioning

    func existingSection(for imagePath: String) -> Section?

    func hasCachedSection(for path: String) -> Bool

    var cachedImagePaths: Set<String> { get }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

    /// A new section of the image, apart from the cached one: never cached,
    /// never attached to the aggregate indexer, so it goes when its caller
    /// lets go of it — and with it everything its definitions resolved. What
    /// a corpus build prints with (proposal `throwaway-corpus-swift-section`):
    /// printing every definition of an image resolves every member and
    /// symbol of it, which a definition keeps for as long as it lives. `nil`
    /// when the image cannot be found.
    func makeUncachedSection(for imagePath: String) async throws -> Section?

    /// The key of the section defining the nominal type a mangled name names.
    func imagePath(definingTypeWithCandidateID candidateID: String) -> String?

    /// The key of the section defining the protocol a mangled name names.
    func imagePath(definingProtocolWithCandidateID candidateID: String) -> String?

    /// The image that declares the `@objc` protocol an Objective-C protocol
    /// record of `runtimeName` belongs to, among the images indexed right now.
    func imagePath(declaringObjCProtocolNamed runtimeName: String) -> String?

    func removeAllSections()
}

extension RuntimeSwiftSectionProviding {
    func section(for imagePath: String) async throws -> (isExisted: Bool, section: Section) {
        try await section(for: imagePath, progressContinuation: nil)
    }
}

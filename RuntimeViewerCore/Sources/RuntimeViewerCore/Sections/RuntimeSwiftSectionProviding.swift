import Foundation

/// The per-image Swift sections of an engine, and the cross-image tables
/// built as they register.
protocol RuntimeSwiftSectionProviding: Actor {
    associatedtype Section: RuntimeSwiftSectioning

    func existingSection(for imagePath: String) -> Section?

    func hasCachedSection(for path: String) -> Bool

    var cachedImagePaths: Set<String> { get }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

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

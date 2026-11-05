import Foundation

/// The per-image Objective-C sections of an engine.
protocol RuntimeObjCSectionProviding: Actor {
    associatedtype Section: RuntimeObjCSectioning

    func existingSection(for imagePath: String) -> Section?

    func hasCachedSection(for path: String) -> Bool

    /// Every image path with a section, under the key it was built for.
    var cachedImagePaths: Set<String> { get }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

    /// The section of the image that defines an Objective-C class or protocol
    /// no image indexed so far was asked about — `nil` when the engine's
    /// catalog knows of none.
    func section(for name: RuntimeObjCName) async throws -> Section?

    func removeAllSections()
}

extension RuntimeObjCSectionProviding {
    func section(for imagePath: String) async throws -> (isExisted: Bool, section: Section) {
        try await section(for: imagePath, progressContinuation: nil)
    }
}

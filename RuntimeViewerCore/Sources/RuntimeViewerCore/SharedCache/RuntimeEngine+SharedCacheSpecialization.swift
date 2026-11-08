import Foundation

// MARK: - Specializing with borrowed images

extension RuntimeEngine {
    /// Before this engine's serving process specializes a type of one of its
    /// own images: the shared cache images it has loaded and this engine
    /// borrowed are indexed there too, as one batch of
    /// `.specializationCandidates`, and the request waits for it.
    ///
    /// The candidates for a generic argument are the types the specializing
    /// process has indexed. Borrowing leaves the shared cache images to their
    /// owners, so without this the process would offer only its own types —
    /// no `String`, no `NSView`. An image indexed there once is not indexed
    /// again; a type of a borrowed image is specialized by its owner, which
    /// has every image it keeps.
    func indexBorrowedImagesForSpecialization(of object: RuntimeObject) async {
        guard sharedCacheOwners != nil, sharedCacheOwner(forImageAt: object.imagePath) == nil else { return }
        let candidateImagePaths = borrowedIndexedImagePaths
            .filter { _isImageLoaded(path: $0) && sharedCacheOwner(forImageAt: $0) != nil }
            .sorted()
        var unindexedImagePaths: [String] = []
        for imagePath in candidateImagePaths {
            let isIndexed = (try? await dispatchToServingProcess(IsImageIndexedCommand(path: imagePath))) ?? false
            if !isIndexed {
                unindexedImagePaths.append(imagePath)
            }
        }
        guard !unindexedImagePaths.isEmpty else { return }
        await backgroundIndexingManager.indexInServingProcess(imagePaths: unindexedImagePaths, reason: .specializationCandidates)
    }
}

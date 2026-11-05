public import Foundation
import Semantic

/// Why a corpus build request ended without a corpus, other than being
/// cancelled.
public enum RuntimeInterfaceCorpusBuildError: Swift.Error, Hashable, Sendable, LocalizedError {
    /// The image is not indexed yet. Asking again once it is will build it.
    case imageNotIndexed(imagePath: String)

    public var errorDescription: String? {
        switch self {
        case .imageNotIndexed(let imagePath):
            "\(imagePath) is not indexed yet, so its interfaces cannot be searched."
        }
    }
}

import Foundation
import Compression

/// What derived data names a kind of stored data by: the first part of its
/// file name, and part of what a container's header must match.
///
/// ASCII letters and digits only. A file is `<kind>-<variant>.rvdd`, and
/// writing a kind deletes the image's files whose names begin with
/// `<kind>-` — its other variants, which have hyphens of their own. A kind
/// with a hyphen in its name would have its files taken for variants of the
/// kind it starts with, and deleted whenever that kind is written.
public struct RuntimeDerivedDataKind: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(
            !rawValue.isEmpty && rawValue.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) },
            "a derived data kind is named with ASCII letters and digits alone: \(rawValue)"
        )
        self.rawValue = rawValue
    }

    /// An image's Find corpus.
    public static let interfaceCorpus = RuntimeDerivedDataKind(rawValue: "InterfaceCorpus")
}

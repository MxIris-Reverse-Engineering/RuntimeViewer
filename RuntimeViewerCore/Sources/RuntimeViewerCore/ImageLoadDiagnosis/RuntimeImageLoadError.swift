public import Foundation

/// A load dyld refused, with what the process that tried worked out about why.
///
/// Its description is dyld's message itself, as a `LocalizedError` and as a
/// `CustomStringConvertible`, so a caller that only shows an error's text shows
/// what it always did. The diagnosis travels in a load's reply rather than on
/// a thrown error: an error crosses an XPC connection as its
/// `localizedDescription` and a socket as its `String(describing:)`, and
/// nothing structured survives either.
public struct RuntimeImageLoadError: Swift.Error, LocalizedError, CustomStringConvertible, Codable, Sendable, Hashable {
    public var dyldMessage: String
    /// `nil` when the serving process could not diagnose the failure.
    public var diagnosis: RuntimeImageLoadDiagnosis?

    public init(dyldMessage: String, diagnosis: RuntimeImageLoadDiagnosis?) {
        self.dyldMessage = dyldMessage
        self.diagnosis = diagnosis
    }

    public var errorDescription: String? {
        dyldMessage
    }

    public var description: String {
        dyldMessage
    }
}

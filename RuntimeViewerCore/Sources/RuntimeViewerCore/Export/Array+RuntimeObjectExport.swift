import Foundation

extension Array where Element == RuntimeObject {
    /// The objects an export writes for these, in order: each one's
    /// `exportedObjects`, with the C++ class template nodes among them opened
    /// first.
    public var exportedObjects: [RuntimeObject] {
        openingCPlusPlusClassTemplateNodes.flatMap(\.exportedObjects)
    }
}

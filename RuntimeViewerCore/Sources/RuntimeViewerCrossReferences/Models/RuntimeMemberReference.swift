import Foundation
// `public import` because this type crosses the public API, and this module
// builds with `InternalImportsByDefault`.
public import RuntimeViewerCore

// The wire types of the cross-reference commands are the types of this
// directory, one per file. Every one is `Codable`: a query crosses from the
// host to whatever process serves the engine, and the answer comes back the
// same way.

/// A member of a runtime object, as a cross reference points at it.
public struct RuntimeMemberReference: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    public let name: String
    public let kind: RuntimeMemberKind
    public let isStatic: Bool

    public init(object: RuntimeObject, name: String, kind: RuntimeMemberKind, isStatic: Bool) {
        self.object = object
        self.name = name
        self.kind = kind
        self.isStatic = isStatic
    }
}

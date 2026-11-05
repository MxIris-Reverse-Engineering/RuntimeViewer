import MetaCodable
import MemberwiseInit
import SwiftStdlibToolbox

/// The identity of a `RuntimeObject` — `(imagePath, name, kind)` — as a value
/// of its own; `RuntimeObject`'s `==` and `hash(into:)` are defined through
/// it. Use the key rather than the object as a dictionary or set key: the two
/// compare and hash alike, but an object stored as a key keeps its whole
/// `children` subtree alive for as long as the entry does.
///
/// All stored fingerprint fields are private so the only valid construction
/// path is `RuntimeObjectKey(_:)`; callers can not assemble a key by hand
/// from arbitrary `(imagePath, name, kind)` components and then dereference
/// it back into a `RuntimeObject` that never existed.
public struct RuntimeObjectKey: Hashable, Sendable {
    private let imagePath: String
    private let name: String
    private let kind: RuntimeObjectKind

    public init(_ object: RuntimeObject) {
        self.imagePath = object.imagePath
        self.name = object.name
        self.kind = object.kind
    }
}

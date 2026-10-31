import Foundation
import Testing
@testable import RuntimeViewerCore

/// The comment structure's wire form: columnar, interned, checked on the way in, and optional on
/// `RuntimeObjectInterface` so that a reply from a peer that predates it still decodes.
@Suite("RuntimeInterfaceCommentStructure")
struct RuntimeInterfaceCommentStructureTests {
    private static let structure = RuntimeInterfaceCommentStructure(
        comments: [
            .init(kind: .fieldOffset, utf8Range: 4 ..< 60, enclosingCommentIndex: nil),
            .init(kind: .fieldLayoutNode, utf8Range: 30 ..< 60, enclosingCommentIndex: 0),
            .init(kind: Kind(rawValue: "somethingNewer"), utf8Range: 70 ..< 80, enclosingCommentIndex: nil),
        ],
        segments: [
            .init(role: .marker, utf8Range: 4 ..< 7, commentIndex: 0),
            .init(role: .label, utf8Range: 7 ..< 19, commentIndex: 0),
            .init(role: .treePrefix, utf8Range: 33 ..< 43, commentIndex: 1),
            .init(role: .value, utf8Range: 55 ..< 60, commentIndex: 1),
        ]
    )

    private typealias Kind = RuntimeInterfaceCommentStructure.Kind

    @Test func roundTripsThroughItsColumnarEncoding() throws {
        let data = try JSONEncoder().encode(Self.structure)
        let decoded = try JSONDecoder().decode(RuntimeInterfaceCommentStructure.self, from: data)

        #expect(decoded == Self.structure)
        // Interned: each kind and role is written once, however many comments use it.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["kindTable"] as? [String])?.count == 3)
        #expect((object["roleTable"] as? [String])?.count == 4)
    }

    @Test func anInterfaceCarriesItAndOneWithoutTheKeyStillDecodes() throws {
        let object = RuntimeObject(name: "Probe", displayName: "Probe", kind: .swift(.type(.struct)), imagePath: "/Probe", children: [])
        let structured = RuntimeObjectInterface(object: object, interfaceString: "struct Probe {}", commentStructure: Self.structure)
        let decodedStructured = try JSONDecoder().decode(RuntimeObjectInterface.self, from: JSONEncoder().encode(structured))
        #expect(decodedStructured.commentStructure == Self.structure)

        // What a peer that predates the field sends: no key at all.
        let plainData = try JSONEncoder().encode(RuntimeObjectInterface(object: object, interfaceString: "struct Probe {}"))
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        #expect(plainObject["commentStructure"] == nil)
        #expect(try JSONDecoder().decode(RuntimeObjectInterface.self, from: plainData).commentStructure == nil)
    }

    @Test func columnsThatDisagreeAreRejected() throws {
        var object = try Self.encodedObject()
        object["commentLengths"] = [1]
        #expect(throws: DecodingError.self) { try Self.decode(object) }
    }

    @Test func indicesOutsideTheirTablesAreRejected() throws {
        var enclosingLater = try Self.encodedObject()
        // A comment may only be enclosed by one that comes before it.
        enclosingLater["commentEnclosingIndices"] = [-1, 2, -1]
        #expect(throws: DecodingError.self) { try Self.decode(enclosingLater) }

        var unknownComment = try Self.encodedObject()
        unknownComment["segmentCommentIndices"] = [0, 0, 1, 9]
        #expect(throws: DecodingError.self) { try Self.decode(unknownComment) }

        var unknownKind = try Self.encodedObject()
        unknownKind["commentKindIndices"] = [0, 1, 5]
        #expect(throws: DecodingError.self) { try Self.decode(unknownKind) }
    }

    @Test func aRangeThatWouldOverflowIsRejected() throws {
        var object = try Self.encodedObject()
        object["segmentOffsets"] = [4, 7, 33, Int.max]
        #expect(throws: DecodingError.self) { try Self.decode(object) }
    }

    private static func encodedObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(structure)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decode(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        _ = try JSONDecoder().decode(RuntimeInterfaceCommentStructure.self, from: data)
    }
}

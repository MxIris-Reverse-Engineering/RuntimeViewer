import Foundation
import Testing
@testable import RuntimeViewerCore

/// The wire format of the search commands' progress: each object once, the
/// results pointing at it by index, and every result back with its object on
/// the other side.
@Suite("RuntimeObjectIndexedBatch")
struct RuntimeObjectIndexedBatchTests {
    private static let child = RuntimeObject(name: "Child", displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [])

    private static let parent = RuntimeObject(name: "Parent", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [child])

    private static let other = RuntimeObject(name: "Other", displayName: "Other", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [])

    @Test("a text search batch sends each object once and gives every match back with its object")
    func textSearchBatchSendsEachObjectOnce() throws {
        let matches = (1 ... 30).map { lineNumber in
            RuntimeInterfaceSearchMatch(
                object: lineNumber.isMultiple(of: 3) ? Self.other : Self.parent,
                lineNumber: lineNumber,
                lineText: "line \(lineNumber)",
                matchRangeInLine: RuntimeTextRange(location: 0, length: 4),
                semanticKind: .standard
            )
        }

        let encodedBatch = try JSONEncoder().encode(RuntimeInterfaceSearchBatch(matches))
        let decodedBatch = try JSONDecoder().decode(RuntimeInterfaceSearchBatch.self, from: encodedBatch)

        #expect(decodedBatch.objects.count == 2)
        #expect(decodedBatch.matches == matches)
        #expect(zip(decodedBatch.matches, matches).allSatisfy { decodedMatch, match in decodedMatch.object.hasSameContent(as: match.object) })
        // Twenty matches of a type with a nested type, ten of another.
        let encodedMatches = try JSONEncoder().encode(matches)
        #expect(encodedBatch.count * 2 < encodedMatches.count)
    }

    @Test("a member search batch sends each object once and gives every match back with its object")
    func memberSearchBatchSendsEachObjectOnce() throws {
        let matches = (1 ... 30).map { number in
            RuntimeMemberMatch(
                object: number.isMultiple(of: 3) ? Self.other : Self.parent,
                member: RuntimeMemberDeclaration(name: "member\(number)", kind: .swiftVariable, isStatic: false, declarationText: "var member\(number): Int", lineNumber: number),
                matchRangeInName: RuntimeTextRange(location: 0, length: 6)
            )
        }

        let encodedBatch = try JSONEncoder().encode(RuntimeMemberSearchBatch(matches))
        let decodedBatch = try JSONDecoder().decode(RuntimeMemberSearchBatch.self, from: encodedBatch)

        #expect(decodedBatch.objects.count == 2)
        #expect(decodedBatch.matches == matches)
        #expect(zip(decodedBatch.matches, matches).allSatisfy { decodedMatch, match in decodedMatch.object.hasSameContent(as: match.object) })
    }

    /// A peer of another build could send a batch whose index points past
    /// its objects; the match is dropped, the rest still arrive.
    @Test("a match whose object index is out of range is dropped, not trapped on")
    func outOfRangeObjectIndexIsDropped() throws {
        let batchFromPeer = #"""
        {
          "objects" : [
            {
              "children" : [],
              "displayName" : "Other",
              "imagePath" : "/images/A",
              "kind" : { "swift" : { "_0" : { "type" : { "_0" : { "struct" : {} } } } } },
              "name" : "Other",
              "properties" : 0
            }
          ],
          "elements" : [
            { "objectIndex" : 0, "payload" : { "lineNumber" : 1, "lineText" : "struct Other", "matchRangeInLine" : { "location" : 7, "length" : 5 }, "semanticKind" : "type" } },
            { "objectIndex" : 5, "payload" : { "lineNumber" : 2, "lineText" : "lost", "matchRangeInLine" : { "location" : 0, "length" : 4 }, "semanticKind" : "standard" } },
            { "objectIndex" : -1, "payload" : { "lineNumber" : 3, "lineText" : "lost", "matchRangeInLine" : { "location" : 0, "length" : 4 }, "semanticKind" : "standard" } }
          ]
        }
        """#

        let decodedBatch = try JSONDecoder().decode(RuntimeInterfaceSearchBatch.self, from: Data(batchFromPeer.utf8))

        #expect(decodedBatch.matches.map(\.lineText) == ["struct Other"])
        #expect(decodedBatch.matches.first?.object.name == "Other")
    }

    /// Two objects can share a key — `==` compares identity only — while
    /// showing different content; each keeps its own slot.
    @Test("an object sharing a key with a different one keeps a slot of its own")
    func objectsSharingAKeyKeepTheirOwnContent() throws {
        let renamed = RuntimeObject(name: "Parent", displayName: "Renamed.Parent", kind: .swift(.type(.struct)), imagePath: "/images/A", children: [])
        let matches = [Self.parent, renamed, Self.parent].enumerated().map { index, object in
            RuntimeInterfaceSearchMatch(object: object, lineNumber: index + 1, lineText: "line", matchRangeInLine: RuntimeTextRange(location: 0, length: 4), semanticKind: .standard)
        }

        let batch = RuntimeInterfaceSearchBatch(matches)

        #expect(batch.objects.count == 2)
        #expect(batch.matches.map(\.object.displayName) == ["Parent", "Renamed.Parent", "Parent"])
    }
}

import Foundation

/// Search results as they cross a connection: each object once, every result
/// pointing at it by index.
///
/// A result's object carries its whole nested tree, and one interface often
/// holds dozens of hits — `View` in SwiftUI, `init` in Foundation — so sending
/// the object with every hit multiplied a batch by the hits per type. This is
/// the progress value of the text and member search commands, which are as
/// new as the corpus: no released peer sends or reads anything else for them.
/// `RuntimeEngine.searchInterfaces` and `searchMembers` hand their callers
/// plain matches again, objects included, so nothing past the engine sees it.
struct RuntimeObjectIndexedBatch<Payload: Codable & Sendable>: Codable, Sendable {
    struct Element: Codable, Sendable {
        let objectIndex: Int
        let payload: Payload
    }

    let objects: [RuntimeObject]

    let elements: [Element]

    /// One slot per object. Within a batch a key comes from one corpus
    /// entry, so the first object seen for a key stands for every result
    /// that names it; one that shares a key yet differs in what it shows gets
    /// a slot of its own, so nothing is lost even then.
    init(_ results: [(object: RuntimeObject, payload: Payload)]) {
        var objects: [RuntimeObject] = []
        var objectIndicesByKey: [RuntimeObjectKey: [Int]] = [:]
        var elements: [Element] = []
        elements.reserveCapacity(results.count)
        for result in results {
            let objectIndex: Int
            if let existingIndex = objectIndicesByKey[result.object.key]?.first(where: { candidateIndex in objects[candidateIndex].hasSameContent(as: result.object) }) {
                objectIndex = existingIndex
            } else {
                objectIndex = objects.count
                objects.append(result.object)
                objectIndicesByKey[result.object.key, default: []].append(objectIndex)
            }
            elements.append(Element(objectIndex: objectIndex, payload: result.payload))
        }
        self.objects = objects
        self.elements = elements
    }

    /// Every result with its object again, in order. An index outside
    /// `objects` — a malformed batch from a peer — drops that result instead
    /// of trapping.
    func results() -> [(object: RuntimeObject, payload: Payload)] {
        elements.compactMap { element in
            guard objects.indices.contains(element.objectIndex) else { return nil }
            return (objects[element.objectIndex], element.payload)
        }
    }
}

/// The progress value of the text search command.
typealias RuntimeInterfaceSearchBatch = RuntimeObjectIndexedBatch<RuntimeInterfaceSearchMatch.Hit>

/// The progress value of the member search command.
typealias RuntimeMemberSearchBatch = RuntimeObjectIndexedBatch<RuntimeMemberMatch.Hit>

extension RuntimeInterfaceSearchMatch {
    /// What a text match carries besides its object.
    struct Hit: Codable, Sendable {
        let lineNumber: Int
        let lineText: String
        let matchRangeInLine: RuntimeTextRange
        let semanticKind: RuntimeSemanticKind
    }
}

extension RuntimeMemberMatch {
    /// What a member match carries besides its object.
    struct Hit: Codable, Sendable {
        let member: RuntimeMemberDeclaration
        let matchRangeInName: RuntimeTextRange
    }
}

extension RuntimeObjectIndexedBatch where Payload == RuntimeInterfaceSearchMatch.Hit {
    init(_ matches: [RuntimeInterfaceSearchMatch]) {
        self.init(matches.map { match in
            (match.object, RuntimeInterfaceSearchMatch.Hit(lineNumber: match.lineNumber, lineText: match.lineText, matchRangeInLine: match.matchRangeInLine, semanticKind: match.semanticKind))
        })
    }

    var matches: [RuntimeInterfaceSearchMatch] {
        results().map { result in
            RuntimeInterfaceSearchMatch(object: result.object, lineNumber: result.payload.lineNumber, lineText: result.payload.lineText, matchRangeInLine: result.payload.matchRangeInLine, semanticKind: result.payload.semanticKind)
        }
    }
}

extension RuntimeObjectIndexedBatch where Payload == RuntimeMemberMatch.Hit {
    init(_ matches: [RuntimeMemberMatch]) {
        self.init(matches.map { match in
            (match.object, RuntimeMemberMatch.Hit(member: match.member, matchRangeInName: match.matchRangeInName))
        })
    }

    var matches: [RuntimeMemberMatch] {
        results().map { result in
            RuntimeMemberMatch(object: result.object, member: result.payload.member, matchRangeInName: result.payload.matchRangeInName)
        }
    }
}

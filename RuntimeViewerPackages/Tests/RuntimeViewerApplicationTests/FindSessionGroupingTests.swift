import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// How a text or member search's hits become the results tree, batch after batch: a search
/// delivers one batch per image, and every batch used to rebuild the row — and its attributed
/// title — of every type found so far, on the main thread, once for each sidebar level's page
/// (PR121.48).
@Suite("FindSession result grouping")
@MainActor
struct FindSessionGroupingTests {
    @Test("a later batch leaves the rows of earlier types the same instances")
    func laterBatchKeepsEarlierRows() throws {
        var groups = FindSession.MatchGroups<RuntimeInterfaceSearchMatch>()
        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 1), FindResultFixtures.hit(in: "Alpha", lineNumber: 2)])
        let alphaAfterFirstBatch = try #require(groups.nodes().first)

        groups.append([FindResultFixtures.hit(in: "Beta", lineNumber: 1)])
        let nodesAfterSecondBatch = groups.nodes()

        #expect(nodesAfterSecondBatch.count == 2)
        #expect(nodesAfterSecondBatch[0] === alphaAfterFirstBatch)
        #expect(nodesAfterSecondBatch[0].children.count == 2)
    }

    @Test("asking again without a new batch builds nothing")
    func repeatedRequestBuildsNothing() throws {
        var groups = FindSession.MatchGroups<RuntimeInterfaceSearchMatch>()
        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 1)])
        let first = groups.nodes()
        let second = groups.nodes()

        #expect(first.count == 1)
        #expect(second.first === first.first)
    }

    @Test("a type that receives more hits gets a new row that holds all of them")
    func moreHitsRebuildTheirType() throws {
        var groups = FindSession.MatchGroups<RuntimeInterfaceSearchMatch>()
        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 1)])
        let alphaBefore = try #require(groups.nodes().first)

        groups.append([FindResultFixtures.hit(in: "Alpha", lineNumber: 9)])
        let alphaAfter = try #require(groups.nodes().first)

        #expect(alphaAfter !== alphaBefore)
        #expect(alphaAfter.children.count == 2)
    }
}

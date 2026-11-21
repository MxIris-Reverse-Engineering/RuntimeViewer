#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
import RuntimeViewerSettings

/// How an engine's recent objects are recorded (`RecentRuntimeObjects`), which an empty editor
/// pane's start page lists (proposal `editor-start-page`).
@Suite("Recent runtime objects")
struct RecentRuntimeObjectsTests {
    private let recentObjects = RecentRuntimeObjects(engineKey: "scope:test-engine")

    @Test("an object shown is recorded first")
    func objectShownIsRecordedFirst() throws {
        let first = Fixtures.runtimeObject(name: "First")
        let second = Fixtures.runtimeObject(name: "Second")

        let afterFirst = try #require(recentObjects.recording(first, in: [:]))
        let afterSecond = try #require(recentObjects.recording(second, in: afterFirst))

        #expect(recentObjects.objects(in: afterSecond).map(\.name) == ["Second", "First"])
    }

    @Test("an object shown again moves to the front instead of being listed twice")
    func objectShownAgainMovesToTheFront() throws {
        var objectsByEngine: [String: [RuntimeObject]] = [:]
        for name in ["First", "Second", "Third"] {
            objectsByEngine = try #require(recentObjects.recording(Fixtures.runtimeObject(name: name), in: objectsByEngine))
        }

        let updated = try #require(recentObjects.recording(Fixtures.runtimeObject(name: "First"), in: objectsByEngine))

        #expect(recentObjects.objects(in: updated).map(\.name) == ["First", "Third", "Second"])
    }

    @Test("the object first already, in the same form, changes nothing")
    func objectFirstAlreadyChangesNothing() throws {
        let object = Fixtures.runtimeObject(name: "First")
        let objectsByEngine = try #require(recentObjects.recording(object, in: [:]))

        #expect(recentObjects.recording(object, in: objectsByEngine) == nil)
    }

    @Test("the object first already, in a new form, is kept in the new form")
    func objectFirstAlreadyInNewFormIsReplaced() throws {
        let object = Fixtures.runtimeObject(name: "Sample")
        let exported = Fixtures.runtimeObject(name: "Sample", properties: [.isSwiftClass])
        let objectsByEngine = try #require(recentObjects.recording(object, in: [:]))

        let updated = try #require(recentObjects.recording(exported, in: objectsByEngine))

        let recorded = recentObjects.objects(in: updated)
        #expect(recorded.count == 1)
        #expect(recorded.first?.properties == [.isSwiftClass])
    }

    @Test("an object is kept without its children, so a new child changes nothing")
    func objectIsKeptWithoutItsChildren() throws {
        let generic = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Nested")])
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Nested"), Fixtures.runtimeObject(name: "Generic<Int>")])
        let objectsByEngine = try #require(recentObjects.recording(generic, in: [:]))

        #expect(recentObjects.objects(in: objectsByEngine).first?.children.isEmpty == true)
        #expect(recentObjects.recording(specialized, in: objectsByEngine) == nil)
    }

    @Test("the list keeps at most the maximum count, dropping the oldest")
    func listKeepsAtMostTheMaximumCount() throws {
        var objectsByEngine: [String: [RuntimeObject]] = [:]
        for index in 0 ..< RecentRuntimeObjects.maximumCount + 3 {
            objectsByEngine = try #require(recentObjects.recording(Fixtures.runtimeObject(name: "Object\(index)"), in: objectsByEngine))
        }

        let recorded = recentObjects.objects(in: objectsByEngine)
        #expect(RecentRuntimeObjects.maximumCount == 10)
        #expect(recorded.count == RecentRuntimeObjects.maximumCount)
        #expect(recorded.first?.name == "Object\(RecentRuntimeObjects.maximumCount + 2)")
        #expect(recorded.last?.name == "Object3")
    }

    @Test("each engine keeps a list of its own")
    func eachEngineKeepsItsOwnList() throws {
        let otherEngineObjects = RecentRuntimeObjects(engineKey: "scope:other-engine")
        let afterFirst = try #require(recentObjects.recording(Fixtures.runtimeObject(name: "Mine"), in: [:]))

        let afterOther = try #require(otherEngineObjects.recording(Fixtures.runtimeObject(name: "Theirs"), in: afterFirst))

        #expect(recentObjects.objects(in: afterOther).map(\.name) == ["Mine"])
        #expect(otherEngineObjects.objects(in: afterOther).map(\.name) == ["Theirs"])
    }
}

/// The recorder each window's document session runs: every object the focused pane shows goes
/// into its engine's recent objects.
@Suite("Recent runtime objects recorder", .serialized)
@MainActor
struct RecentRuntimeObjectsRecorderTests {
    @Test("an object shown in the focused pane is recorded first in its engine's list")
    func objectShownIsRecorded() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeObjectsRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let engineKey = Settings.Indexing.EngineReference.key(for: environment.documentState.runtimeEngine)

        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Second"), in: .focusedTab))

        try await waitUntil {
            environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["Second", "First"]
        }
    }

    @Test("switching back to a tab moves its object to the front")
    func switchingBackToATabMovesItsObjectToTheFront() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeObjectsRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let documentState = environment.documentState
        let engineKey = Settings.Indexing.EngineReference.key(for: documentState.runtimeEngine)

        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        let firstTabID = documentState.editorArea.focusedPane.activeTab.id
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Second"), in: .newTab))
        try await waitUntil {
            environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["Second", "First"]
        }

        documentState.selectionRouter.trigger(.switchTab(firstTabID))

        try await waitUntil {
            environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["First", "Second"]
        }
    }

    @Test("an open document session records what its window shows, and a closed one stops")
    func documentSessionRecordsWhileOpen() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RecentRuntimeObjectsRecorderTests.session")
        let session = environment.make { DocumentSession(runtimeEngine: engine) }
        let documentState = session.documentState
        let engineKey = Settings.Indexing.EngineReference.key(for: documentState.runtimeEngine)

        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "BeforeOpening"), in: .focusedTab))
        environment.make { session.open() }
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "WhileOpen"), in: .focusedTab))
        try await waitUntil {
            environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.first?.name == "WhileOpen"
        }

        session.close()
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "AfterClosing"), in: .focusedTab))

        // A record is written from the route itself, and a read waits for every write queued
        // before it: what is not there now was never recorded.
        #expect(environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["WhileOpen", "BeforeOpening"])
    }

    @Test("an empty tab records nothing")
    func emptyTabRecordsNothing() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeObjectsRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let engineKey = Settings.Indexing.EngineReference.key(for: environment.documentState.runtimeEngine)

        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        try await waitUntil {
            environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["First"]
        }

        environment.documentState.selectionRouter.trigger(.newTab)

        #expect(environment.documentState.selectedRuntimeObject == nil)
        #expect(environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["First"])
    }

    @Test("the object on screen shown in a new form does not move to the front")
    func newFormOfTheObjectOnScreenDoesNotMove() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeObjectsRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let documentState = environment.documentState
        let engineKey = Settings.Indexing.EngineReference.key(for: documentState.runtimeEngine)
        let generic = Fixtures.runtimeObject(name: "Generic")
        documentState.selectionRouter.trigger(.open(generic, in: .focusedTab))
        environment.appDefaults.recentRuntimeObjectsByEngine[engineKey] = [Fixtures.runtimeObject(name: "SeenElsewhere"), generic]

        documentState.selectionRouter.trigger(.selectAtRoot(Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])))

        #expect(documentState.selectedRuntimeObject?.children.count == 1)
        #expect(environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["SeenElsewhere", "Generic"])
    }

    @Test("two windows on one engine keep one list")
    func twoWindowsOnOneEngineKeepOneList() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RecentRuntimeObjectsRecorderTests.twoWindows")
        let firstDocumentState = DocumentState(runtimeEngine: engine)
        let secondDocumentState = DocumentState(runtimeEngine: engine)
        let recorders = environment.make {
            [RecentRuntimeObjectsRecorder(documentState: firstDocumentState), RecentRuntimeObjectsRecorder(documentState: secondDocumentState)]
        }
        defer { withExtendedLifetime(recorders) {} }

        firstDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "InFirstWindow"), in: .focusedTab))
        secondDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "InSecondWindow"), in: .focusedTab))

        let engineKey = Settings.Indexing.EngineReference.key(for: engine)
        #expect(environment.appDefaults.recentRuntimeObjectsByEngine[engineKey]?.map(\.name) == ["InSecondWindow", "InFirstWindow"])
    }
}

#endif

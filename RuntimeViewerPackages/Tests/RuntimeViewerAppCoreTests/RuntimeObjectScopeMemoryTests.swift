import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerSettings

/// The stored form of a remembered Filter Scope (`RuntimeObjectScope`'s
/// `Codable` conformance).
@Suite("RuntimeObjectScope persistence")
struct RuntimeObjectScopePersistenceTests {
    @Test("a scope comes back from its stored form unchanged")
    func scopeRoundTrips() throws {
        var scope = RuntimeObjectScope()
        scope.toggleKind(.swift(.type(.struct)))
        scope[.notExported] = .exclude
        scope[.generic] = .only

        let decodedScope = try JSONDecoder().decode(RuntimeObjectScope.self, from: JSONEncoder().encode(scope))

        #expect(decodedScope == scope)
    }

    @Test("the empty scope stores nothing")
    func emptyScopeStoresNothing() throws {
        let data = try JSONEncoder().encode(RuntimeObjectScope())

        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(try JSONDecoder().decode(RuntimeObjectScope.self, from: data) == RuntimeObjectScope())
    }

    @Test("kinds are stored as the ones left out, so that a kind added later is let in")
    func kindsAreStoredAsTheOnesLeftOut() throws {
        var scope = RuntimeObjectScope()
        scope.toggleKind(.c(.union))

        let storedObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any])
        let storedKinds = try #require(storedObject["excludedKinds"] as? [Any])

        #expect(storedKinds.count == 1)
        let decodedScope = try JSONDecoder().decode(RuntimeObjectScope.self, from: JSONSerialization.data(withJSONObject: storedObject))
        #expect(decodedScope.includedKinds == RuntimeObjectScope.allRepresentableKinds.subtracting([.c(.union)]))
    }

    @Test("a kind, a property or a state this release does not know costs only that entry")
    func unknownEntriesCostOnlyThemselves() throws {
        let unionKind = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([RuntimeObjectKind.c(.union)])) as? [Any])
        let storedObject: [String: Any] = [
            "excludedKinds": unionKind + [["kindFromALaterRelease": [String: Any]()]],
            "propertyStates": [
                "notExported": "exclude",
                "propertyFromALaterRelease": "only",
                "generic": "stateFromALaterRelease",
            ],
        ]

        let decodedScope = try JSONDecoder().decode(RuntimeObjectScope.self, from: JSONSerialization.data(withJSONObject: storedObject))

        var expectedScope = RuntimeObjectScope()
        expectedScope.toggleKind(.c(.union))
        expectedScope[.notExported] = .exclude
        #expect(decodedScope == expectedScope)
    }

    @Test("a stored scope that does not decode costs its image, not the file")
    func undecodableScopeCostsItsImage() {
        let storedObject: [String: Any] = [
            "engine": [
                "/usr/lib/libobjc.A.dylib": ["propertyStates": ["notExported": "exclude"]],
                "/usr/lib/broken.dylib": "not a scope",
            ],
        ]
        var diagnostics: [String] = []

        let decodedStore = [String: [String: RuntimeObjectScope]].decodedLeniently(from: storedObject, diagnostics: &diagnostics)

        #expect(decodedStore?["engine"]?.keys.sorted() == ["/usr/lib/libobjc.A.dylib"])
        #expect(decodedStore?["engine"]?["/usr/lib/libobjc.A.dylib"]?[.notExported] == .exclude)
        #expect(diagnostics.count == 1)
    }
}

@Suite("RuntimeObjectScopeMemory")
struct RuntimeObjectScopeMemoryTests {
    private let libobjcMemory = RuntimeObjectScopeMemory(engineKey: "scope:engine", imagePath: "/usr/lib/libobjc.A.dylib")

    private let foundationMemory = RuntimeObjectScopeMemory(engineKey: "scope:engine", imagePath: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation")

    private let otherEngineMemory = RuntimeObjectScopeMemory(engineKey: "process:Other", imagePath: "/usr/lib/libobjc.A.dylib")

    private var excludingNotExported: RuntimeObjectScope {
        var scope = RuntimeObjectScope()
        scope[.notExported] = .exclude
        return scope
    }

    @Test("an image with nothing remembered gets the empty scope")
    func imageWithNothingRememberedGetsEmptyScope() {
        #expect(libobjcMemory.scope(in: [:]) == RuntimeObjectScope())
        #expect(libobjcMemory.scope(in: otherEngineMemory.remembering(excludingNotExported, in: [:])) == RuntimeObjectScope())
    }

    @Test("an active scope is remembered under the engine and the image")
    func activeScopeIsRemembered() {
        let store = libobjcMemory.remembering(excludingNotExported, in: [:])

        #expect(store == ["scope:engine": ["/usr/lib/libobjc.A.dylib": excludingNotExported]])
        #expect(libobjcMemory.scope(in: store) == excludingNotExported)
    }

    @Test("an inactive scope removes the image, and the engine once it has no image left")
    func inactiveScopeRemovesTheEntry() {
        let storeWithTwoImages = foundationMemory.remembering(excludingNotExported, in: libobjcMemory.remembering(excludingNotExported, in: [:]))

        let storeWithOneImage = libobjcMemory.remembering(RuntimeObjectScope(), in: storeWithTwoImages)
        #expect(storeWithOneImage == ["scope:engine": [foundationMemory.imagePath: excludingNotExported]])

        let emptyStore = foundationMemory.remembering(RuntimeObjectScope(), in: storeWithOneImage)
        #expect(emptyStore.isEmpty)
    }

    @Test("other images and other engines are left alone")
    func otherEntriesAreLeftAlone() {
        var specializedOnly = RuntimeObjectScope()
        specializedOnly[.specialized] = .only
        let store = otherEngineMemory.remembering(specializedOnly, in: foundationMemory.remembering(specializedOnly, in: [:]))

        let updatedStore = libobjcMemory.remembering(excludingNotExported, in: store)

        #expect(foundationMemory.scope(in: updatedStore) == specializedOnly)
        #expect(otherEngineMemory.scope(in: updatedStore) == specializedOnly)
        #expect(libobjcMemory.scope(in: updatedStore) == excludingNotExported)
    }

    @Test("an engine is known by the key Always Index matches engines by")
    func engineKeyIsTheAlwaysIndexKey() async throws {
        let engine = try await TestRuntimeEngine.shared()

        let memory = RuntimeObjectScopeMemory(engine: engine, imagePath: TestImages.libobjc)

        #expect(memory.engineKey == Settings.Indexing.EngineReference.key(for: engine))
        #expect(memory.imagePath == TestImages.libobjc)
    }
}

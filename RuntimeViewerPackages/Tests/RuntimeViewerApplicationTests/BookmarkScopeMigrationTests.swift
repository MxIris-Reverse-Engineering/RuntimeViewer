#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerApplication
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Fixtures are hand-written, never copied from a real machine's
/// `Application Support`: a real file carries a device UDID and a device name,
/// and a test that depended on one would also depend on whose laptop it ran on.
@Suite("BookmarkScopeMigration")
struct BookmarkScopeMigrationTests {
    private func imageBookmark(_ name: String) -> RuntimeImageBookmark {
        RuntimeImageBookmark(imageNode: RuntimeImageNode(name))
    }

    private func objectBookmark(_ name: String, imagePath: String = "/usr/lib/libobjc.dylib") -> RuntimeObjectBookmark {
        RuntimeObjectBookmark(object: RuntimeObject(
            name: name,
            displayName: name,
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: imagePath,
            children: []
        ))
    }

    private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) rethrows -> Result {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkScopeMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try body(directoryURL)
    }

    private func write(_ contents: String, named name: String, in directoryURL: URL) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Mapping

    @Test("A non-Bonjour source maps across unchanged")
    func nonBonjourSourceMapsAcross() {
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(
                source: .remote(name: "My Mac (Mac Catalyst)", identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .client),
                payload: [imageBookmark("AppKit")]
            )
        ])

        #expect(outcome.migrated.keys.sorted() == ["v1:remote:client:com.RuntimeViewer.RuntimeSource.MacCatalyst"])
        #expect(outcome.discardedSourceCount == 0)
        #expect(outcome.mergedSourceCount == 0)
    }

    @Test("The dead entries a peer accumulated collapse into one scope, in disk order")
    func accumulatedRelaunchEntriesMerge() {
        // This is the ordinary shape of the file this migration was written
        // for: one entry per relaunch of the same peer, differing only in a
        // process identifier the scope drops.
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-100"), role: .client), payload: [imageBookmark("UIKit")]),
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-200"), role: .client), payload: [imageBookmark("Foundation")]),
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-300"), role: .client), payload: [imageBookmark("CoreGraphics")]),
        ])

        let key = "v1:bonjour:client:\(deviceIdentifier):SpringBoard"
        #expect(outcome.migrated.keys.sorted() == [key])
        #expect(outcome.migrated[key]?.map(\.imageNode.name) == ["UIKit", "Foundation", "CoreGraphics"])
        #expect(outcome.mergedSourceCount == 2)
    }

    @Test("Merging is a union, and duplicates survive only once")
    func mergeDeduplicates() {
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-100"), role: .client), payload: [imageBookmark("UIKit"), imageBookmark("Foundation")]),
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-200"), role: .client), payload: [imageBookmark("Foundation"), imageBookmark("CoreGraphics")]),
        ])

        let key = "v1:bonjour:client:\(deviceIdentifier):SpringBoard"
        #expect(outcome.migrated[key]?.map(\.imageNode.name) == ["UIKit", "Foundation", "CoreGraphics"])
    }

    @Test("Object bookmarks merge per image path")
    func objectBookmarksMergePerImagePath() {
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let outcome = BookmarkScopeMigration.migrateObjectBookmarks(from: [
            .init(
                source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-100"), role: .client),
                payload: ["/usr/lib/libobjc.dylib": [objectBookmark("NSObject")]]
            ),
            .init(
                source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-200"), role: .client),
                payload: [
                    "/usr/lib/libobjc.dylib": [objectBookmark("NSObject"), objectBookmark("NSProxy")],
                    "/System/Library/Frameworks/UIKit.framework/UIKit": [objectBookmark("UIView", imagePath: "/System/Library/Frameworks/UIKit.framework/UIKit")],
                ]
            ),
        ])

        let key = "v1:bonjour:client:\(deviceIdentifier):SpringBoard"
        let migrated = outcome.migrated[key]
        #expect(migrated?["/usr/lib/libobjc.dylib"]?.map(\.object.name) == ["NSObject", "NSProxy"])
        #expect(migrated?["/System/Library/Frameworks/UIKit.framework/UIKit"]?.map(\.object.name) == ["UIView"])
    }

    @Test("A client and a server for the same peer stay apart")
    func rolesDoNotMerge() {
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(source: .remote(name: "Peer", identifier: "shared", role: .client), payload: [imageBookmark("UIKit")]),
            .init(source: .remote(name: "Peer", identifier: "shared", role: .server), payload: [imageBookmark("Foundation")]),
        ])

        #expect(outcome.migrated.keys.sorted() == ["v1:remote:client:shared", "v1:remote:server:shared"])
        #expect(outcome.mergedSourceCount == 0)
    }

    @Test("A source with no recoverable identity is dropped, not filed under a guess")
    func unrecoverableSourceIsDropped() {
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            // Pre-simulator-injection: the identifier is a service name and
            // carries no device identity, so no key a running engine would ever
            // ask for can be derived. Filing it anyway would look migrated and
            // read empty forever.
            .init(source: .bonjour(name: "JHs-iPhone (RuntimeViewer)", identifier: "JHs-iPhone (RuntimeViewer)", role: .client), payload: [imageBookmark("UIKit")]),
            .init(source: .local, payload: [imageBookmark("AppKit")]),
        ])

        #expect(outcome.migrated.keys.sorted() == ["v1:local::"])
        #expect(outcome.discardedSourceCount == 1)
    }

    @Test("Two devices running the same process keep separate scopes")
    func twoDevicesStayApart() {
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(source: .bonjour(name: "SpringBoard", identifier: "11111111-2222-3333-4444-555555555555-100", role: .client), payload: [imageBookmark("UIKit")]),
            .init(source: .bonjour(name: "SpringBoard", identifier: "99999999-8888-7777-6666-555555555555-100", role: .client), payload: [imageBookmark("Foundation")]),
        ])

        #expect(outcome.migrated.count == 2)
        #expect(outcome.mergedSourceCount == 0)
    }

    @Test("A migrated key is the key a live engine asks for")
    func migratedKeyMatchesLiveEngine() throws {
        // The property the whole migration hangs on. Anything else and the
        // bookmarks land somewhere nothing ever reads.
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: [
            .init(source: .bonjour(name: "SpringBoard", identifier: .init(rawValue: "\(deviceIdentifier)-4242"), role: .client), payload: [imageBookmark("UIKit")])
        ])

        let liveScope = try #require(
            RuntimeBookmarkScope.bonjour(deviceID: deviceIdentifier, processName: "SpringBoard", role: .client)
        )
        #expect(outcome.migrated[liveScope.bookmarkKey]?.count == 1)
    }

    // MARK: - Reading the old files

    @Test("A key/value-alternating archive keeps every duplicate key, in disk order")
    func keyedArchiveKeepsDuplicateKeys() throws {
        try withTemporaryDirectory { directoryURL in
            // Decoding this as `[RuntimeSource: …]` would return *one* entry:
            // the two keys differ only in the display name, which
            // `RuntimeSource.==` ignores, so the second silently overwrites the
            // first. Reading the raw array is what stops the migration losing
            // data before it starts.
            let url = try write(
                """
                [
                  {"bonjour": {"identifier": "DEV-100", "name": "First Name", "role": {"client": {}}}},
                  [{"imageNode": {"name": "UIKit", "absolutePath": "/UIKit", "children": []}}],
                  {"bonjour": {"identifier": "DEV-100", "name": "Second Name", "role": {"client": {}}}},
                  [{"imageNode": {"name": "Foundation", "absolutePath": "/Foundation", "children": []}}]
                ]
                """,
                named: "archive.json",
                in: directoryURL
            )

            let entries = try #require(
                BookmarkScopeMigration.entries(ofPayload: [RuntimeImageBookmark].self, inKeyedArchiveAt: url)
            )
            #expect(entries.count == 2)
            #expect(entries.map(\.source.description) == ["First Name", "Second Name"])
        }
    }

    @Test("A malformed pair is skipped, the rest are kept")
    func keyedArchiveSkipsMalformedPair() throws {
        try withTemporaryDirectory { directoryURL in
            let url = try write(
                """
                [
                  {"bonjour": {"identifier": "DEV-100", "name": "Good", "role": {"client": {}}}},
                  [{"imageNode": {"name": "UIKit", "absolutePath": "/UIKit", "children": []}}],
                  {"nonsense": {}},
                  [],
                  {"local": {}},
                  [{"imageNode": {"name": "AppKit", "absolutePath": "/AppKit", "children": []}}]
                ]
                """,
                named: "archive.json",
                in: directoryURL
            )

            let entries = try #require(
                BookmarkScopeMigration.entries(ofPayload: [RuntimeImageBookmark].self, inKeyedArchiveAt: url)
            )
            #expect(entries.count == 2)
            #expect(entries.map(\.source.description) == ["Good", "My Mac"])
        }
    }

    @Test("An odd element count drops only the trailing key")
    func keyedArchiveHandlesOddCount() throws {
        try withTemporaryDirectory { directoryURL in
            let url = try write(
                """
                [
                  {"local": {}},
                  [{"imageNode": {"name": "AppKit", "absolutePath": "/AppKit", "children": []}}],
                  {"bonjour": {"identifier": "DEV-100", "name": "Orphan", "role": {"client": {}}}}
                ]
                """,
                named: "archive.json",
                in: directoryURL
            )

            let entries = try #require(
                BookmarkScopeMigration.entries(ofPayload: [RuntimeImageBookmark].self, inKeyedArchiveAt: url)
            )
            #expect(entries.count == 1)
        }
    }

    @Test("A missing or unusable archive migrates nothing rather than crashing")
    func missingOrUnusableArchive() throws {
        try withTemporaryDirectory { directoryURL in
            #expect(BookmarkScopeMigration.entries(
                ofPayload: [RuntimeImageBookmark].self,
                inKeyedArchiveAt: directoryURL.appendingPathComponent("nothing-here.json")
            ) == nil)

            let notJSON = try write("{{{", named: "broken.json", in: directoryURL)
            #expect(BookmarkScopeMigration.entries(ofPayload: [RuntimeImageBookmark].self, inKeyedArchiveAt: notJSON) == nil)

            let wrongShape = try write(#"{"not": "an array"}"#, named: "wrong.json", in: directoryURL)
            #expect(BookmarkScopeMigration.entries(ofPayload: [RuntimeImageBookmark].self, inKeyedArchiveAt: wrongShape) == nil)
        }
    }

    @Test("The oldest flat form still reads, source field and all")
    func flatArchiveStillReads() throws {
        try withTemporaryDirectory { directoryURL in
            // `RuntimeImageBookmark` no longer has a source to decode into, so
            // this shape needs its own type — and still has to work, because a
            // user upgrading across several releases arrives here first.
            let url = try write(
                """
                [
                  {"source": {"local": {}}, "imageNode": {"name": "AppKit", "absolutePath": "/AppKit", "children": []}},
                  {"source": {"bonjour": {"identifier": "DEV-100", "name": "SpringBoard", "role": {"client": {}}}}, "imageNode": {"name": "UIKit", "absolutePath": "/UIKit", "children": []}},
                  {"imageNode": {"name": "NoSource", "absolutePath": "/NoSource", "children": []}}
                ]
                """,
                named: "flat.json",
                in: directoryURL
            )

            let elements = try #require(
                BookmarkScopeMigration.flatEntries(ofElement: BookmarkScopeMigration.LegacyFlatImageBookmark.self, inArchiveAt: url)
            )
            // The third entry has no source and is skipped, not defaulted.
            #expect(elements.count == 2)
            #expect(elements.map(\.imageNode.name) == ["AppKit", "UIKit"])
        }
    }
}

#endif

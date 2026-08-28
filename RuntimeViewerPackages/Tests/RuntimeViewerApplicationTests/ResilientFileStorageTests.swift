#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerApplication
import RuntimeViewerCore

/// Everything here writes into a fresh temporary directory.
///
/// Never the default one: the real wrappers live in
/// `Application Support/AppStorage`, shared with the running app, and a test
/// that took the default path would overwrite the user's own bookmarks. That
/// has actually happened in this project with a different store.
@Suite("ResilientFileStorage")
struct ResilientFileStorageTests {
    private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) rethrows -> Result {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResilientFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try body(directoryURL)
    }

    private func write(_ contents: String, named name: String, in directoryURL: URL) throws {
        try Data(contents.utf8).write(to: directoryURL.appendingPathComponent(name))
    }

    private func quarantineFiles(in directoryURL: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path))?
            .filter { $0.contains("corrupted-") }
            .sorted() ?? []
    }

    @Test("An absent file reads as the default value")
    func absentFileReadsAsDefault() {
        withTemporaryDirectory { directoryURL in
            let storage = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            #expect(storage.wrappedValue.isEmpty)
        }
    }

    @Test("A written value comes back")
    func roundTrip() {
        withTemporaryDirectory { directoryURL in
            let storage = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            storage.setSynchronously(["v1:local::": [RuntimeImageBookmark(imageNode: RuntimeImageNode("libobjc.dylib"))]])

            let reader = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            #expect(reader.wrappedValue["v1:local::"]?.count == 1)
            #expect(reader.wrappedValue["v1:local::"]?.first?.imageNode.name == "libobjc.dylib")
        }
    }

    @Test("One malformed entry costs that entry and nothing else")
    func malformedEntryIsSkipped() throws {
        try withTemporaryDirectory { directoryURL in
            // Two scopes, three bookmarks. The middle one of the first scope is
            // missing the field a bookmark cannot do without.
            try write(
                """
                {
                  "v1:local::": [
                    {"imageNode": {"name": "libobjc.dylib", "absolutePath": "/usr/lib/libobjc.dylib", "children": []}},
                    {"whatIsThis": true},
                    {"imageNode": {"name": "Foundation", "absolutePath": "/System/Library/Frameworks/Foundation.framework/Foundation", "children": []}}
                  ],
                  "v1:remote:client:peer": [
                    {"imageNode": {"name": "UIKit", "absolutePath": "/System/Library/Frameworks/UIKit.framework/UIKit", "children": []}}
                  ]
                }
                """,
                named: "bookmarks.json",
                in: directoryURL
            )

            let storage = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            let loaded = storage.wrappedValue

            #expect(loaded["v1:local::"]?.map(\.imageNode.name) == ["libobjc.dylib", "Foundation"])
            #expect(loaded["v1:remote:client:peer"]?.map(\.imageNode.name) == ["UIKit"])
            // Nothing was quarantined: the file itself was fine.
            #expect(quarantineFiles(in: directoryURL).isEmpty)
        }
    }

    @Test("A file that is not JSON at all is moved aside, never overwritten")
    func unparseableFileIsQuarantined() throws {
        try withTemporaryDirectory { directoryURL in
            try write("this is not json {{{", named: "bookmarks.json", in: directoryURL)

            let storage = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            #expect(storage.wrappedValue.isEmpty)

            let quarantined = quarantineFiles(in: directoryURL)
            #expect(quarantined.count == 1)
            // The bytes are still there, which is the whole point.
            let recovered = try String(contentsOf: directoryURL.appendingPathComponent(quarantined[0]), encoding: .utf8)
            #expect(recovered == "this is not json {{{")
            #expect(!FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("bookmarks.json").path))
        }
    }

    @Test("Valid JSON of the wrong shape is quarantined too")
    func shapeMismatchIsQuarantined() throws {
        try withTemporaryDirectory { directoryURL in
            // The pre-migration form: a key/value-alternating array where an
            // object now belongs.
            try write(#"["a", [], "b", []]"#, named: "bookmarks.json", in: directoryURL)

            let storage = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            )
            #expect(storage.wrappedValue.isEmpty)
            #expect(quarantineFiles(in: directoryURL).count == 1)
        }
    }

    @Test("A second corruption does not destroy the evidence of the first")
    func quarantineDoesNotOverwriteItself() throws {
        try withTemporaryDirectory { directoryURL in
            try write("first corruption", named: "bookmarks.json", in: directoryURL)
            _ = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            ).wrappedValue

            try write("second corruption", named: "bookmarks.json", in: directoryURL)
            _ = ResilientFileStorage<[String: [RuntimeImageBookmark]]>(
                wrappedValue: [:], "bookmarks", directoryURL: directoryURL
            ).wrappedValue

            let quarantined = quarantineFiles(in: directoryURL)
            #expect(quarantined.count == 2, "both corruptions should survive, got \(quarantined)")
            let contents = try Set(quarantined.map {
                try String(contentsOf: directoryURL.appendingPathComponent($0), encoding: .utf8)
            })
            #expect(contents == ["first corruption", "second corruption"])
        }
    }

    @Test("A nested dictionary tolerates a malformed leaf the same way")
    func nestedDictionaryToleratesMalformedLeaf() throws {
        try withTemporaryDirectory { directoryURL in
            try write(
                """
                {
                  "v1:local::": {
                    "/usr/lib/libobjc.dylib": [
                      {"object": {"name": "NSObject", "displayName": "NSObject", "kind": {"objc": {"_0": {"type": {"_0": {"class": {}}}}}}, "imagePath": "/usr/lib/libobjc.dylib", "children": [], "properties": 0}},
                      {"object": "not an object"}
                    ],
                    "/wrong/shape": "not even a list"
                  }
                }
                """,
                named: "objects.json",
                in: directoryURL
            )

            let storage = ResilientFileStorage<[String: [String: [RuntimeObjectBookmark]]]>(
                wrappedValue: [:], "objects", directoryURL: directoryURL
            )
            let loaded = storage.wrappedValue
            #expect(loaded["v1:local::"]?["/usr/lib/libobjc.dylib"]?.count == 1)
            #expect(loaded["v1:local::"]?["/wrong/shape"] == nil)
            #expect(quarantineFiles(in: directoryURL).isEmpty)
        }
    }
}

#endif

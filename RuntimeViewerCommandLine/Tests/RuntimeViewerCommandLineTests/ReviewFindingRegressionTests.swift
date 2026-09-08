import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerCommandLineInterface

/// Contracts the PR #112 review found broken. Each one is cheap to restate and
/// expensive to rediscover: what resolves a relative path, which of several
/// matching images wins, how a table pads a cell, which host may delete the
/// socket file, and whether a settings file that no longer decodes says so.
@Suite("Review finding regressions", .serialized, .timeLimit(.minutes(2)))
struct ReviewFindingRegressionTests {
    // MARK: - The client resolves paths, never the host

    @Test("A bare file name that exists in the caller's directory is sent as an absolute path")
    func bareFileNameInWorkingDirectoryBecomesAbsolute() {
        // The host inherits its working directory from whichever client
        // happened to start it, so a relative path means something different
        // there — or nothing at all.
        let resolved = imageArgument("libExample.dylib", fileExists: { $0 == "libExample.dylib" })
        #expect(resolved.hasPrefix("/"), "A file in the caller's directory was passed through for the host to resolve")
    }

    @Test("A short name that is not a file in the caller's directory passes through")
    func shortNameStaysAShortName() {
        #expect(imageArgument("AppKit", fileExists: { _ in false }) == "AppKit")
    }

    // MARK: - Short-name matching is deterministic

    @Test("A substring that several images match resolves to the same one whatever the input order")
    func substringMatchIsOrderIndependent() {
        let paths = [
            "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
            "/System/Library/PrivateFrameworks/CloudKitAuthenticationPlugin.framework/CloudKitAuthenticationPlugin",
            "/System/Library/Frameworks/CloudKit.framework/Versions/A/CloudKit",
        ]
        let matches = Set([paths, paths.reversed(), paths.shuffled()].compactMap { ImageResolver.match("kit", in: $0) })
        #expect(matches.count == 1, "The same query picked \(matches.count) different images depending on order: \(matches)")
    }

    @Test("Two candidates sharing a display name resolve to the same one whatever the input order")
    func candidateSelectionIsOrderIndependent() {
        // `Candidate.imagePath` exists precisely because same-named types in
        // different images are a real case.
        let candidates = [
            RuntimeSpecializationRequest.Candidate(id: "a", displayName: "Element", imagePath: "/B", isGeneric: false, kind: .struct),
            RuntimeSpecializationRequest.Candidate(id: "b", displayName: "Element", imagePath: "/A", isGeneric: false, kind: .struct),
            RuntimeSpecializationRequest.Candidate(id: "c", displayName: "Element", imagePath: "/C", isGeneric: false, kind: .class),
        ]
        let chosen = Set([candidates, candidates.reversed(), candidates.shuffled()].compactMap {
            CommandExecutor.candidate(named: "Element", among: $0)?.id
        })
        #expect(chosen == ["b"], "--argument picked \(chosen) depending on the order the engine happened to return")
    }

    // MARK: - Table cells are padded, not truncated

    @Test("A cell holding an astral-plane character keeps its content and its gutter")
    func wideCharacterCellIsNotTruncated() {
        // `padding(toLength:)` counts UTF-16 units while the column widths
        // count characters: one flag emoji is two units and one character, so
        // the pad length lands three short and cuts the cell mid-surrogate.
        let table = TextTable(header: ["NAME", "KIND"], rows: [["Flag🇺🇸Foo", "class"]])
        let rendered = table.render()
        #expect(rendered.contains("Flag🇺🇸Foo"), "The cell was truncated: \(rendered.debugDescription)")
        #expect(!rendered.contains("\u{FFFD}"), "A surrogate pair was cut in half")
        let bodyLine = try? #require(rendered.split(separator: "\n").last.map(String.init))
        #expect(bodyLine?.contains("Flag🇺🇸Foo  class") == true, "The two-space gutter was eaten: \(String(describing: bodyLine))")
    }

    // MARK: - Only the host that bound the socket removes it

    @Test("A host that never bound does not delete the socket of the one that did")
    func unstartedHostLeavesTheSocketAlone() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let running = try await InProcessHost.start(paths: paths, resolver: StubSourceResolver())

        // Loses the instance lock, so it never listens — proposal 0006's case.
        let loser = CommandLineHostServer(
            configuration: CommandLineHostServer.Configuration(paths: paths, kind: .standalone, idleTimeout: nil),
            executor: CommandExecutor(sourceResolver: StubSourceResolver())
        )
        do {
            try await loser.start()
            Issue.record("The second host should not have started while the first holds the lock")
        } catch {
            // Expected.
        }
        await loser.stop(reason: .signal)

        #expect(
            UnixDomainSocket.isHostListening(at: paths.socketURL.path),
            "The host that never bound deleted the socket the running one's clients dial"
        )
        await running.stop()
    }

    // MARK: - A settings file that no longer decodes says so

    @Test("A settings file that does not decode is reported, not taken for an absent one")
    func undecodableSettingsFileIsReported() throws {
        let settingsFileURL = try Self.writeSettingsFile(contents: "this file is not JSON at all")
        defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

        let reader = ApplicationOptionsReader(bundleIdentifiers: [], settingsFileURL: settingsFileURL)
        switch reader.readSettings() {
        case .unreadable:
            break
        case .absent:
            Issue.record("A settings file that stopped decoding passed for a missing one, so `--options app` silently used defaults")
        case .decoded:
            Issue.record("The malformed file decoded")
        }
    }

    @Test("A settings key whose type changed decodes to the default, and nothing can report it")
    func settingsTypeDriftIsSwallowedBeforeThisModuleSeesIt() throws {
        // Not a defect of the reader, and not fixable here: `GenerationOptions`
        // is a MetaCodable `@Codable` whose every property carries `@Default`,
        // so a key of the wrong type falls back to the default value instead of
        // throwing. `--options app` therefore cannot tell a settings schema
        // change from settings that happen to hold the defaults. Locked down
        // here so the next reader knows the diagnostic above has that limit.
        let settingsFileURL = try Self.writeSettingsFile(contents: #"{"transformer": "this used to be an object"}"#)
        defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

        let reader = ApplicationOptionsReader(bundleIdentifiers: [], settingsFileURL: settingsFileURL)
        guard case .decoded = reader.readSettings() else {
            Issue.record("MetaCodable's @Default no longer swallows a type mismatch; the reader can report schema drift now")
            return
        }
    }

    private static func writeSettingsFile(contents: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/rvcli-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsFileURL = directory.appendingPathComponent("settings.json")
        try Data(contents.utf8).write(to: settingsFileURL)
        return settingsFileURL
    }
}

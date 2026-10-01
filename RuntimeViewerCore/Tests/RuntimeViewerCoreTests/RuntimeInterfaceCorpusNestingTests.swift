import Foundation
import Testing
@testable import RuntimeViewerCore

/// What an interface prints inline — its nested types, a root protocol's
/// default implementations — is printed once, found once and never lends its
/// lines to the members of the object around it. Checked on Foundation, whose
/// format styles nest `CodingKeys` enums whose cases share their names with
/// the fields of the type around them.
@Suite("Find corpus around nested definitions", .serialized)
struct RuntimeInterfaceCorpusNestingTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    /// One engine holding Foundation's corpus for the whole suite: building
    /// it takes most of a minute in a debug build.
    private static let foundationEngine = Task<RuntimeEngine, Swift.Error> {
        let engine = RuntimeEngine(source: .local, engineID: "test-corpus-nesting")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        _ = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)
        return engine
    }

    private static func foundationEntries() async throws -> [RuntimeInterfaceCorpusEntry] {
        let engine = try await foundationEngine.value
        return try #require(await engine.interfaceCorpusStore.corpus(for: Anchors.foundationPath)?.entries)
    }

    @Test("a field is located on its own declaration, not on the nested CodingKeys case that shares its name")
    func fieldLocatedOnItsOwnDeclaration() async throws {
        let engine = try await Self.foundationEngine.value
        var matches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "style", kinds: [.swiftField], isCaseSensitive: true)) { batch in
            matches += batch
        }
        // `PersonNameComponents.FormatStyle` prints its nested `CodingKeys`
        // (`case style`, `case locale`) above its own `var style`.
        let field = try #require(matches.first { $0.object.displayName.hasSuffix("PersonNameComponents.FormatStyle") && $0.member.name == "style" })
        #expect(field.member.declarationText.hasPrefix("var style:"), "located on: \(field.member.declarationText)")
    }

    @Test("every Swift member is located in its own object's body, never inside a nested type")
    func swiftMembersLocatedInTheirOwnBody() async throws {
        let entries = try await Self.foundationEntries()
        var misplaced: [String] = []
        var locatedCount = 0
        for entry in entries where entry.object.kind.isSwift {
            let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
            for member in entry.members {
                guard let lineNumber = member.lineNumber else { continue }
                locatedCount += 1
                // An object's own members are printed one level in; a nested
                // type's members two levels or more.
                let line = lines[lineNumber - 1]
                if line.prefix(while: { $0 == " " }).count != 4 {
                    misplaced.append("\(entry.object.displayName) \(member.kind.rawValue) \(member.name) → line \(lineNumber): \(line)")
                }
            }
        }
        #expect(locatedCount > 1000)
        #expect(misplaced.isEmpty, "\(misplaced.count) of \(locatedCount) members located inside a nested type, e.g.\n\(misplaced.prefix(10).joined(separator: "\n"))")
    }

    @Test("every nested type's block is found in the interface of the object listing it")
    func everyNestedBlockFound() async throws {
        let entries = try await Self.foundationEntries()
        let entryKeys = Set(entries.map(\.object.key))
        var nestedCount = 0
        var unfound: [String] = []
        for entry in entries {
            let children = entry.object.children.filter { entryKeys.contains($0.key) }
            nestedCount += children.count
            if entry.nestedDefinitionRanges.count != children.count {
                unfound.append("\(entry.object.displayName): \(entry.nestedDefinitionRanges.count) of \(children.count) found")
            }
        }
        #expect(nestedCount > 100)
        #expect(unfound.isEmpty, "\(unfound.count) objects with nested blocks not found, e.g.\n\(unfound.prefix(10).joined(separator: "\n"))")
    }

    @Test("no interface prints the same extension twice")
    func noExtensionPrintedTwice() async throws {
        let entries = try await Self.foundationEntries()
        var repeated: [String] = []
        for entry in entries where entry.object.kind.isSwift {
            var seen: Set<String> = []
            for block in Self.extensionBlocks(of: entry.interface.text) where !seen.insert(block).inserted {
                repeated.append("\(entry.object.displayName): \(block.prefix(while: { $0 != "\n" }))")
            }
        }
        // `LocalizedError`'s default implementations have been seen printed
        // twice in an export of Foundation.
        #expect(repeated.isEmpty, "\(repeated.count) extensions printed again, e.g.\n\(repeated.prefix(10).joined(separator: "\n"))")
    }

    /// The corpus takes a nested type's own definition out of its parent's
    /// print rather than printing it again; what comes out must be what
    /// printing the type on its own gives, or a search would show other text
    /// than the content pane — `draft-find-navigator` §1.1, option D.
    @Test("every nested type's corpus interface is exactly its interface printed on its own")
    func nestedInterfaceEqualsItsOwnPrint() async throws {
        let engine = try await Self.foundationEngine.value
        let entries = try await Self.foundationEntries()
        let nestedKeys = Set(entries.flatMap { $0.object.children.map(\.key) })
        let nestedEntries = entries.filter { nestedKeys.contains($0.object.key) }
        let firstNestedEntry = try #require(nestedEntries.first)
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: firstNestedEntry.object.imagePath))
        var different: [String] = []
        for entry in nestedEntries {
            let outcomes = try await section.corpusPrints(of: [entry.object], transformer: .default)
            guard case .printed(let ownPrint) = outcomes.first else {
                different.append("\(entry.object.displayName): does not print on its own")
                continue
            }
            if ownPrint.interface != entry.interface {
                different.append("\(entry.object.displayName): text")
            } else if ownPrint.visibilityRegions != entry.visibilityRegions {
                different.append("\(entry.object.displayName): visibility regions")
            } else if ownPrint.nestedDefinitionRanges != entry.nestedDefinitionRanges {
                different.append("\(entry.object.displayName): nested blocks")
            }
        }
        #expect(nestedEntries.count > 100)
        #expect(different.isEmpty, "\(different.count) of \(nestedEntries.count) nested types differ, e.g.\n\(different.prefix(10).joined(separator: "\n"))")
    }

    /// A protocol declared in an extension of a type from another module —
    /// `extension NSNotificationCenter { protocol AsyncMessage }` — is printed
    /// without its default implementations, the way its parent prints it
    /// inline, so its own interface has to bring them along.
    @Test("a protocol declared in another module's extension shows its default implementations")
    func extensionProtocolShowsDefaultImplementations() async throws {
        let engine = try await Self.foundationEngine.value
        let entries = try await Self.foundationEntries()
        let firstSwiftEntry = try #require(entries.first { $0.object.kind.isSwift })
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: firstSwiftEntry.object.imagePath))
        var checkedCount = 0
        var missing: [String] = []
        for entry in entries where entry.object.kind.isSwift {
            guard case .protocol(let definition) = try? await section.printedDefinitions(for: entry.object).first,
                  definition.extensionContext != nil,
                  !definition.defaultImplementationExtensions.isEmpty
            else { continue }
            checkedCount += 1
            let extensionCount = Self.extensionBlocks(of: entry.interface.text).count
            if extensionCount < definition.defaultImplementationExtensions.count {
                missing.append("\(entry.object.displayName): \(extensionCount) of \(definition.defaultImplementationExtensions.count) default implementation extensions")
            }
        }
        #expect(checkedCount > 0, "Foundation declares no protocol with default implementations in an extension any more")
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }

    /// The options a search reads the corpus under: none — everything — or
    /// the defaults, which hide comments inside the nested blocks and so
    /// move them in the projected text.
    enum SearchOptions: String, CaseIterable, Sendable {
        case everything
        case defaults

        var generationOptions: RuntimeObjectInterface.GenerationOptions? {
            switch self {
            case .everything: nil
            case .defaults: RuntimeObjectInterface.GenerationOptions()
            }
        }
    }

    @Test("a hit inside a nested type is reported once, in the nested type", arguments: SearchOptions.allCases)
    func nestedHitReportedOnce(options: SearchOptions) async throws {
        let engine = try await Self.foundationEngine.value
        var matches: [RuntimeInterfaceSearchMatch] = []
        let query = RuntimeInterfaceSearchQuery(text: "var parseStrategy: Foundation.PersonNameComponents.ParseStrategy", isCaseSensitive: true, generationOptions: options.generationOptions)
        _ = try await engine.searchInterfaces(query) { batch in
            matches += batch
        }
        // Declared once, in `PersonNameComponents.FormatStyle`, which its
        // parent `PersonNameComponents` prints inline.
        #expect(matches.map(\.object.displayName).count == 1, "found in \(matches.map(\.object.displayName))")
        #expect(matches.first?.object.displayName.hasSuffix("PersonNameComponents.FormatStyle") == true)
    }

    /// Every block that starts with `extension` at the start of a line, up
    /// to the next one, trimmed — the unit the printer emits per extension
    /// definition.
    private static func extensionBlocks(of text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("extension ") {
                if let current {
                    blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                }
                current = [line]
            } else {
                current?.append(line)
            }
        }
        if let current {
            blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return blocks
    }
}

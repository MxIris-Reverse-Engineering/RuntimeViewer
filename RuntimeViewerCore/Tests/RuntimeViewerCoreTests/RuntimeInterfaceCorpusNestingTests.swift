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

    /// Members of different kinds share names — an Objective-C property and
    /// its ivar, a class and an instance property, an initializer's label and
    /// a static function — so a member located by its name alone lands on
    /// another declaration's line. Checked with words only, so the check does
    /// not lean on the span rules the locator uses.
    @Test("every located member's line declares a member of its own kind")
    func locatedLinesDeclareTheirMembers() async throws {
        let entries = try await Self.foundationEntries()
        var misplaced: [String] = []
        var listedCountByKind: [RuntimeMemberKind: Int] = [:]
        var locatedCountByKind: [RuntimeMemberKind: Int] = [:]
        for entry in entries {
            let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
            for member in entry.members {
                listedCountByKind[member.kind, default: 0] += 1
                guard let lineNumber = member.lineNumber else { continue }
                locatedCountByKind[member.kind, default: 0] += 1
                let line = lines[lineNumber - 1]
                if !Self.line(line, declares: member) {
                    misplaced.append("\(entry.object.displayName) \(member.kind.rawValue)\(member.isStatic ? " static" : "") \(member.name) → line \(lineNumber): \(line)")
                }
            }
        }
        #expect(misplaced.isEmpty, "\(misplaced.count) members located on another declaration's line, e.g.\n\(misplaced.prefix(10).joined(separator: "\n"))")
        let locationRates = RuntimeMemberKind.allCases.map { kind in
            "\(kind.rawValue) \(locatedCountByKind[kind, default: 0]) of \(listedCountByKind[kind, default: 0])"
        }
        for kind in [RuntimeMemberKind.objcProperty, .objcIvar, .objcMethod, .swiftFunction] {
            let listedCount = listedCountByKind[kind, default: 0]
            let locatedCount = locatedCountByKind[kind, default: 0]
            #expect(listedCount > 0 && locatedCount * 100 >= listedCount * 99, "\(kind.rawValue): \(locatedCount) of \(listedCount) located; all kinds: \(locationRates.joined(separator: ", "))")
        }
    }

    /// What a line has to read like for `member` to be declared on it —
    /// words only, so the check does not lean on the span rules the locator
    /// uses.
    private static func line(_ line: Substring, declares member: RuntimeMemberDeclaration) -> Bool {
        let trimmedLine = line.drop(while: { $0 == " " })
        let words = Set(trimmedLine.split(whereSeparator: { !$0.isLetter && $0 != "@" }).map(String.init))
        let readsStatic = words.contains("static") || words.contains("class")
        switch member.kind {
        case .objcProperty:
            return trimmedLine.hasPrefix("@property") && words.contains("class") == member.isStatic
        case .objcIvar:
            // One level into the `@interface` braces; an expanded struct's
            // fields sit deeper.
            let indentation = line.prefix(while: { $0 == " " }).count
            return indentation == 4 && !trimmedLine.hasPrefix("@property") && !trimmedLine.hasPrefix("-") && !trimmedLine.hasPrefix("+")
        case .objcMethod:
            return trimmedLine.hasPrefix(member.isStatic ? "+" : "-")
        case .swiftInitializer:
            return words.contains("init")
        case .swiftFunction:
            return words.contains("func") && readsStatic == member.isStatic
        case .swiftSubscript:
            return words.contains("subscript") && readsStatic == member.isStatic
        case .swiftVariable, .swiftField:
            return (words.contains("var") || words.contains("let")) && readsStatic == member.isStatic
        case .swiftEnumCase:
            return words.contains("case")
        }
    }

    /// The printer trails a top-level protocol with its default
    /// implementations itself, so nothing in the definitions the corpus
    /// prints from lists them — the member list has to.
    @Test("a top-level protocol's default implementations are found by a member search")
    func topLevelProtocolDefaultImplementationsAreMembers() async throws {
        let engine = try await Self.foundationEngine.value
        var matches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "errorDescription", kinds: [.swiftVariable], isCaseSensitive: true)) { batch in
            matches += batch
        }
        let isLocalizedError: (RuntimeObject) -> Bool = { $0.kind == .swift(.type(.protocol)) && $0.displayName.hasSuffix("LocalizedError") }
        // The requirement and the default implementation the printer trails
        // the protocol with.
        let protocolMatches = matches.filter { isLocalizedError($0.object) && $0.member.name == "errorDescription" }
        #expect(protocolMatches.count == 2, "\(protocolMatches.map(\.member.declarationText))")

        let entry = try #require(try await Self.foundationEntries().first { isLocalizedError($0.object) })
        let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstExtensionLineNumber = try #require(lines.firstIndex { $0.hasPrefix("extension ") }) + 1
        let lineNumbers = protocolMatches.compactMap(\.member.lineNumber)
        #expect(Set(lineNumbers).count == 2)
        #expect(lineNumbers.contains { $0 > firstExtensionLineNumber }, "no match inside the default implementations: \(lineNumbers)")
    }

    @Test("every protocol with default implementations has a member located among them")
    func protocolDefaultImplementationsLocated() async throws {
        let engine = try await Self.foundationEngine.value
        let entries = try await Self.foundationEntries()
        let firstSwiftEntry = try #require(entries.first { $0.object.kind.isSwift })
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: firstSwiftEntry.object.imagePath))
        var checkedCount = 0
        var missing: [String] = []
        for entry in entries where entry.object.kind == .swift(.type(.protocol)) {
            // Only symbol-scan extension blocks, which every placement
            // prints: a synthesized one is not printed for a nested protocol.
            guard case .protocol(let definition) = try? await section.printedDefinitions(for: entry.object).first,
                  definition.defaultImplementationExtensions.contains(where: \.isAttachedToProtocolDefinition)
            else { continue }
            checkedCount += 1
            let lines = entry.interface.text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let firstExtensionLineIndex = lines.firstIndex(where: { $0.hasPrefix("extension ") }) else {
                missing.append("\(entry.object.displayName): prints no extension")
                continue
            }
            if !entry.members.contains(where: { ($0.lineNumber ?? 0) > firstExtensionLineIndex + 1 }) {
                missing.append("\(entry.object.displayName): no member located in its default implementations")
            }
        }
        #expect(checkedCount > 10)
        #expect(missing.isEmpty, "\(missing.count) of \(checkedCount) protocols, e.g.\n\(missing.prefix(10).joined(separator: "\n"))")
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

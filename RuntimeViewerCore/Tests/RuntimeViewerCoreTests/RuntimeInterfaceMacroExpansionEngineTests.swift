import Foundation
import Observation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// A class compiled from `@Observable` with another nested in it, so a folded
/// interface shows two attributes and the engine sends an expansion for each.
@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@Observable
public final class MacroExpansionObservableFixture {
    public var count: Int = 0

    public var title: String = ""

    @Observable
    public final class NestedFixture {
        public var isEnabled: Bool = false
    }
}

// MARK: - Tests

/// What the engine sends when a request asks for the attached macros
/// (`marksAttachedMacros`): MachOSwiftSection marks each attribute the folded
/// interface prints and prints each expansion, and the engine hands every
/// attribute's range over with the expansion of the type it is on — the
/// nested type's attribute with the nested type's expansion. The text is
/// left exactly as a request without it gets.
@Suite("Macro expansions from the engine", .serialized)
struct RuntimeInterfaceMacroExpansionEngineTests {
    private struct FixtureMissing: Error {}

    /// This test bundle's image, where the fixtures are declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private static let attribute = "@Observation.Observable"

    /// One engine for the suite, and the outer fixture as the sidebar lists it, the nested one
    /// among its children.
    private static let shared = Task<(engine: RuntimeEngine, fixture: RuntimeObject), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeInterfaceMacroExpansionEngineTests")
        try await engine.connect()
        let fixture = try await engine.objects(in: testBundlePath).first { object in
            object.kind.isSwift
                && (object.displayName == "MacroExpansionObservableFixture" || object.displayName.hasSuffix(".MacroExpansionObservableFixture"))
        }
        guard let fixture else { throw FixtureMissing() }
        return (engine, fixture)
    }

    /// The options a request is made with: comments on, so the comment structure has something
    /// to number around the attributes.
    private static func options(
        marksAttachedMacros: Bool,
        marksCommentStructure: Bool = false,
        expandsMacros: Bool = false
    ) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.printFieldOffset = true
        options.swiftInterfaceOptions.printMemberAddress = true
        options.swiftInterfaceOptions.expandsMacros = expandsMacros
        options.marksAttachedMacros = marksAttachedMacros
        options.marksCommentStructure = marksCommentStructure
        return options
    }

    private static func interface(_ options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface {
        let (engine, fixture) = try await shared.value
        return try #require(try await engine.interface(for: fixture, options: options))
    }

    /// The UTF-8 bytes `range` covers in `text`.
    private static func text(in range: Range<Int>, of text: String) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    /// The text of `part`'s content.
    private static func content(of part: RuntimeInterfaceMacroExpansion.Part) -> String {
        part.content.string
    }

    /// `parts`, each followed by the parts of its nested expansions, depth first: everything an
    /// expansion shows once every attribute in it is expanded too.
    private static func allParts(of parts: [RuntimeInterfaceMacroExpansion.Part]) -> [RuntimeInterfaceMacroExpansion.Part] {
        parts.flatMap { part in [part] + part.nestedExpansions.flatMap { allParts(of: $0.parts) } }
    }

    /// The line `range` starts on, up to the end of `range`, and how far it is indented.
    private static func anchorLine(of range: Range<Int>, in text: String) -> (line: String, indentation: Int) {
        let bytes = Array(text.utf8)
        var lineStart = range.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let line = String(decoding: bytes[lineStart ..< range.upperBound], as: UTF8.self)
        return (line, line.prefix { $0 == " " }.count)
    }

    @Test func eachAttributeComesWithTheExpansionOfItsType() async throws {
        let interface = try await Self.interface(Self.options(marksAttachedMacros: true))
        let text = interface.interfaceString.string
        let expansions = try #require(interface.macroExpansions)

        #expect(expansions.count == 2)
        for expansion in expansions {
            #expect(expansion.macroName == "Observation.Observable")
            #expect(Self.text(in: expansion.attributeUTF8Range, of: text) == Self.attribute)
        }
        #expect(expansions.map(\.attributeUTF8Range.lowerBound) == expansions.map(\.attributeUTF8Range.lowerBound).sorted())

        let outer = Self.allParts(of: try #require(expansions.first).parts).map(Self.content(of:)).joined(separator: "\n")
        #expect(outer.contains("_count"))
        #expect(outer.contains("_title"))
        #expect(outer.contains("_$observationRegistrar"))
        #expect(!outer.contains("_isEnabled"))

        let nested = Self.allParts(of: try #require(expansions.last).parts).map(Self.content(of:)).joined(separator: "\n")
        #expect(nested.contains("_isEnabled"))
        #expect(!nested.contains("_count"))
        #expect(nested.contains("NestedFixture"))
    }

    /// The two levels Xcode shows: expanding `@Observable` puts the `@ObservationTracked` it
    /// attaches above each tracked property's declaration, the generated members above the type's
    /// closing brace, inside the body, and the generated conformance below it; expanding that
    /// attribute puts the property's accessors and storage below its declaration. The nested
    /// type's parts go by its own declarations and its own brace, one level further in.
    @Test func eachPartGoesWhereXcodePutsIt() async throws {
        let interface = try await Self.interface(Self.options(marksAttachedMacros: true))
        let text = interface.interfaceString.string
        let expansions = try #require(interface.macroExpansions)
        try #require(expansions.count == 2)

        for (expansion, propertyNames, braceIndentation) in [(expansions[0], ["count", "title"], 0), (expansions[1], ["isEnabled"], 4)] {
            let attributeParts = expansion.parts.filter { Self.content(of: $0).hasSuffix("ObservationTracked") }
            #expect(attributeParts.count == propertyNames.count)
            for (part, propertyName) in zip(attributeParts, propertyNames) {
                let (line, indentation) = Self.anchorLine(of: part.anchorUTF8Range, in: text)
                #expect(part.placement == .aboveLine)
                #expect(line.hasSuffix(Self.text(in: part.anchorUTF8Range, of: text)))
                #expect(line.contains("var \(propertyName):"), "\(line)")
                #expect(indentation == braceIndentation + 4, "\(line)")

                try #require(part.nestedExpansions.count == 1)
                let trackedExpansion = try #require(part.nestedExpansions.first)
                let attributeText = String(decoding: Array(Self.content(of: part).utf8)[trackedExpansion.attributeUTF8Range], as: UTF8.self)
                #expect(trackedExpansion.macroName == "Observation.ObservationTracked")
                #expect(attributeText.hasSuffix("ObservationTracked"), "\(attributeText)")
                try #require(trackedExpansion.parts.count == 1)
                let trackedPart = try #require(trackedExpansion.parts.first)
                #expect(trackedPart.placement == .belowLine)
                #expect(trackedPart.anchorUTF8Range == part.anchorUTF8Range)
                #expect(Self.content(of: trackedPart).contains("_\(propertyName)"))
            }

            let membersPart = try #require(expansion.parts.first { Self.content(of: $0).contains("_$observationRegistrar") })
            let conformancePart = try #require(expansion.parts.last)
            #expect(Self.content(of: conformancePart).hasPrefix("extension "))
            #expect(membersPart.placement == .aboveLine)
            #expect(conformancePart.placement == .belowLine)
            #expect(membersPart.anchorUTF8Range == conformancePart.anchorUTF8Range)
            let (braceLine, indentation) = Self.anchorLine(of: membersPart.anchorUTF8Range, in: text)
            #expect(braceLine.trimmingCharacters(in: .whitespaces) == "}", "\(braceLine)")
            #expect(indentation == braceIndentation, "\(braceLine)")
        }
        // The outer type's brace is the last line of its print.
        let outerBrace = try #require(expansions.first?.parts.last).anchorUTF8Range
        let textAfterOuterBrace = Self.text(in: outerBrace.upperBound ..< text.utf8.count, of: text)
        #expect(textAfterOuterBrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(textAfterOuterBrace)")
    }

    /// A caller that names the object without its children — a link followed to it — gets the
    /// nested type's attribute with the nested type's expansion all the same: the types are
    /// looked up in the definitions printed, not in the sidebar's tree.
    @Test func anObjectWithoutItsChildrenGetsTheSameExpansions() async throws {
        let (engine, fixture) = try await Self.shared.value
        let childless = RuntimeObject(name: fixture.name, displayName: fixture.displayName, kind: fixture.kind, imagePath: fixture.imagePath, children: [])
        #expect(!fixture.children.isEmpty)
        var options = Self.options(marksAttachedMacros: true)
        // Options no other test uses, so the section prints anew instead of answering from its
        // cache, which is keyed by the object's name, not its children.
        options.swiftInterfaceOptions.printVTableOffset = true

        let interface = try #require(try await engine.interface(for: childless, options: options))
        let expansions = try #require(interface.macroExpansions)

        #expect(expansions.count == 2)
        let outerParts = Self.allParts(of: try #require(expansions.first).parts)
        let nestedParts = Self.allParts(of: try #require(expansions.last).parts)
        #expect(outerParts.contains { Self.content(of: $0).contains("_count") })
        #expect(nestedParts.contains { Self.content(of: $0).contains("_isEnabled") })
    }

    /// The parts carry no indentation of their own and no line break around them: the content
    /// pane indents each from the line it goes at.
    @Test func partsHaveNoIndentationOfTheirOwn() async throws {
        let interface = try await Self.interface(Self.options(marksAttachedMacros: true))
        let parts = try #require(interface.macroExpansions).flatMap { Self.allParts(of: $0.parts) }

        #expect(!parts.isEmpty)
        for part in parts {
            let content = Self.content(of: part)
            #expect(!content.hasPrefix(" ") && !content.hasPrefix("\n") && !content.hasSuffix("\n"), "\(content)")
        }
        let attributePart = try #require(parts.first { Self.content(of: $0).hasSuffix("ObservationTracked") })
        #expect(Self.content(of: attributePart).hasPrefix("@"), "the attribute alone: \(Self.content(of: attributePart))")
        let propertyPart = try #require(parts.first { Self.content(of: $0).contains("var _count") })
        #expect(Self.content(of: propertyPart).hasPrefix("{"), "the accessor block first: \(Self.content(of: propertyPart))")
    }

    @Test func theTextIsTheSameWithOrWithoutTheMarks() async throws {
        let marked = try await Self.interface(Self.options(marksAttachedMacros: true, marksCommentStructure: true))
        let unmarked = try await Self.interface(Self.options(marksAttachedMacros: false, marksCommentStructure: true))

        #expect(marked.interfaceString == unmarked.interfaceString)
        #expect(unmarked.macroExpansions == nil)
        // The attributes' regions share the table with the comments and are no comments: the
        // structure is the one a request without them gets, numbering included.
        #expect(marked.commentStructure == unmarked.commentStructure)
        #expect(marked.commentStructure?.comments.isEmpty == false)
    }

    @Test func theFoldedFormIsTheDefault() async throws {
        let folded = try await Self.interface(Self.options(marksAttachedMacros: false))
        let text = folded.interfaceString.string

        #expect(text.components(separatedBy: Self.attribute).count - 1 == 2)
        #expect(!text.contains("_$observationRegistrar"))
        // The conformance the macro generated prints with the type, not as an entry of its own,
        // and goes with the rest of the expansion.
        #expect(!text.contains(": Observation.Observable"))
    }

    /// Expanded, the interface prints what the binary holds and no attribute is left to expand.
    @Test func anExpandedInterfaceHasNothingToExpand() async throws {
        let expanded = try await Self.interface(Self.options(marksAttachedMacros: true, expandsMacros: true))
        let text = expanded.interfaceString.string

        #expect(text.contains("_$observationRegistrar"))
        #expect(!text.contains(Self.attribute))
        #expect(expanded.macroExpansions?.isEmpty == true)
    }
}

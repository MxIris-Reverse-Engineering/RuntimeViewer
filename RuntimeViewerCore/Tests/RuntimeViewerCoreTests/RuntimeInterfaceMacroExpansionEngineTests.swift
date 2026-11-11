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

        let outerExpansion = try #require(expansions.first).expansionString.string
        #expect(outerExpansion.contains("_$observationRegistrar"))
        #expect(outerExpansion.contains("_count"))
        #expect(outerExpansion.contains("_title"))
        #expect(!outerExpansion.contains("_isEnabled"))

        let nestedExpansion = try #require(expansions.last).expansionString.string
        #expect(nestedExpansion.contains("_isEnabled"))
        #expect(!nestedExpansion.contains("_count"))
        #expect(nestedExpansion.split(separator: "\n").last?.contains("NestedFixture") == true)
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
        #expect(expansions.first?.expansionString.string.contains("_count") == true)
        #expect(expansions.last?.expansionString.string.contains("_isEnabled") == true)
    }

    /// The members print one level in from the attribute and the generated conformance at its
    /// level, the way the content pane lays them out below the attribute's line.
    @Test func anExpansionIsIndentedAsTheTypeBody() async throws {
        let interface = try await Self.interface(Self.options(marksAttachedMacros: true))
        let expansion = try #require(interface.macroExpansions?.first).expansionString.string
        let lines = expansion.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(!expansion.hasPrefix("\n"))
        #expect(!expansion.hasSuffix("\n"))
        #expect(lines.first?.hasPrefix("    ") == true)
        let conformance = try #require(lines.last)
        #expect(conformance.hasPrefix("extension "))
        #expect(conformance.contains("Observation.Observable"))
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

import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

// MARK: - Fixtures

/// A field that is a struct of its own, so the field offset tree has a row
/// with rows below it.
struct CommentDecorationsStructFixture {
    var count: Int
    var nested: CommentDecorationsNestedFixture
}

struct CommentDecorationsNestedFixture {
    var first: Int16
    var second: Double
}

/// Payload cases, so the enum layout prints a block per case.
enum CommentDecorationsEnumFixture {
    case none
    case count(Int)
    case pair(Int8, Int8)
}

// MARK: - Tests

/// The policy run on what the engine sends: the comment structures
/// MachOSwiftSection and MachOObjCSection mark, separated by the engine, for
/// this bundle's Swift fixtures and libobjc's `NSObject`.
/// `InterfaceCommentDecorationsTests` pins each rule on hand-written
/// structures; this checks that the rules hold together on real ones —
/// nothing outside a comment is hidden, coloured or tagged, every comment's
/// marker is hidden, and the field tree and the case blocks collapse.
@Suite("InterfaceCommentDecorations on the engine's comment structure", .serialized)
struct InterfaceCommentDecorationsEngineTests {
    private struct Printed {
        let object: RuntimeObject
        let text: String
        let structure: RuntimeInterfaceCommentStructure
        let decorations: InterfaceCommentDecorations
    }

    /// This test bundle's image, where the Swift fixtures are declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private static let fixtureNames = ["CommentDecorationsStructFixture", "CommentDecorationsEnumFixture"]

    /// Every comment either language prints, with the structure asked for.
    private static let options: RuntimeObjectInterface.GenerationOptions = {
        var options = RuntimeObjectInterface.GenerationOptions(
            objcHeaderOptions: ObjCGenerationOptions(
                addIvarOffsetComments: true,
                addPropertyAttributesComments: true,
                addMethodIMPAddressComments: true,
                addPropertyAccessorAddressComments: true
            ),
            swiftInterfaceOptions: SwiftGenerationOptions(
                printFieldOffset: true,
                printExpandedFieldOffset: true,
                printVTableOffset: true,
                printPWTOffset: true,
                printMemberAddress: true,
                printTypeLayout: true,
                printEnumLayout: true
            )
        )
        options.marksCommentStructure = true
        return options
    }()

    /// A private engine: listing this bundle's objects indexes it, which the
    /// shared engine must not be put through.
    private static let shared = Task<[Printed], any Error> {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "InterfaceCommentDecorationsEngineTests", loading: [TestImages.libobjc])
        let swiftFixtures = try await engine.objects(in: testBundlePath).filter { object in
            object.kind.isSwift && fixtureNames.contains { object.displayName == $0 || object.displayName.hasSuffix(".\($0)") }
        }
        let nsObject = try await engine.objects(in: TestImages.libobjc).filter { $0.kind == .objc(.type(.class)) && $0.name == "NSObject" }
        var printed: [Printed] = []
        for object in swiftFixtures + nsObject {
            let interface = try #require(try await engine.interface(for: object, options: options), "no interface for \(object.displayName)")
            let structure = try #require(interface.commentStructure, "no comment structure for \(object.displayName)")
            printed.append(Printed(
                object: object,
                text: interface.interfaceString.string,
                structure: structure,
                decorations: InterfaceCommentDecorations(structure: structure, interfaceString: interface.interfaceString)
            ))
        }
        return printed
    }

    /// The UTF-16 ranges of the comments no other comment encloses.
    private static func outermostCommentRanges(of printed: Printed) -> [Range<Int>] {
        let outermostComments = printed.structure.comments.filter { $0.enclosingCommentIndex == nil }
        let utf16Offsets = InterfaceCommentDecorations.utf16Offsets(
            of: outermostComments.flatMap { [$0.utf8Range.lowerBound, $0.utf8Range.upperBound] },
            in: printed.text
        )
        return outermostComments.compactMap { comment in
            guard let lowerBound = utf16Offsets[comment.utf8Range.lowerBound], let upperBound = utf16Offsets[comment.utf8Range.upperBound] else { return nil }
            return lowerBound ..< upperBound
        }
    }

    private static func isInsideAComment(_ range: NSRange, _ commentRanges: [Range<Int>]) -> Bool {
        commentRanges.contains { $0.lowerBound <= range.location && NSMaxRange(range) <= $0.upperBound }
    }

    @Test("the fixtures and NSObject are printed, and each gets decorations")
    func everyObjectIsDecorated() async throws {
        let printed = try await Self.shared.value
        #expect(printed.count == Self.fixtureNames.count + 1, "\(printed.map(\.object.displayName))")
        for entry in printed {
            #expect(!entry.decorations.tags.isEmpty, "\(entry.object.displayName)")
            #expect(Self.outermostCommentRanges(of: entry).count == entry.structure.comments.filter { $0.enclosingCommentIndex == nil }.count, "\(entry.object.displayName): a comment's range falls inside a character")
        }
    }

    @Test("nothing outside a comment is hidden, coloured or tagged")
    func decorationsStayInsideComments() async throws {
        for entry in try await Self.shared.value {
            let commentRanges = Self.outermostCommentRanges(of: entry)
            for range in entry.decorations.hiddenRanges {
                #expect(Self.isInsideAComment(range, commentRanges), "\(entry.object.displayName): hidden \(range) is outside every comment")
            }
            for run in entry.decorations.runs {
                #expect(Self.isInsideAComment(run.range, commentRanges), "\(entry.object.displayName): a \(run.style) run at \(run.range) is outside every comment")
            }
            for tag in entry.decorations.tags {
                #expect(Self.isInsideAComment(tag.range, commentRanges), "\(entry.object.displayName): a tag at \(tag.range) is outside every comment")
            }
        }
    }

    @Test("every comment's marker is hidden")
    func markersAreHidden() async throws {
        for entry in try await Self.shared.value {
            for commentRange in Self.outermostCommentRanges(of: entry) {
                #expect(entry.decorations.hiddenRanges.contains { NSLocationInRange(commentRange.lowerBound, $0) }, "\(entry.object.displayName): the marker at \(commentRange.lowerBound) shows")
            }
        }
    }

    @Test("the field tree's row with rows below it and the enum's case blocks collapse, from the end of a line")
    func treesAndCaseBlocksCollapse() async throws {
        let printed = try await Self.shared.value
        let structPrint = try #require(printed.first { $0.object.displayName.hasSuffix("CommentDecorationsStructFixture") })
        let enumPrint = try #require(printed.first { $0.object.displayName.hasSuffix("CommentDecorationsEnumFixture") })
        #expect(!structPrint.decorations.collapsibles.isEmpty, "\(structPrint.text)")
        #expect(!enumPrint.decorations.collapsibles.isEmpty, "\(enumPrint.text)")
        for entry in [structPrint, enumPrint] {
            let text = entry.text as NSString
            let commentRanges = Self.outermostCommentRanges(of: entry)
            for collapsible in entry.decorations.collapsibles {
                #expect(collapsible.startsCollapsed)
                #expect(text.character(at: collapsible.foldRange.location) == UInt16(UInt8(ascii: "\n")), "\(entry.object.displayName): a fold starts mid-line")
                #expect(Self.isInsideAComment(collapsible.foldRange, commentRanges), "\(entry.object.displayName): a fold reaches outside its comment")
            }
        }
    }
}

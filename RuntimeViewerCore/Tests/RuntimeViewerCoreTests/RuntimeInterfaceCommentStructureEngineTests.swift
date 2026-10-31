import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Stored fields of a few layouts, one of them a struct of its own, so the
/// interface prints field offsets — the expanded tree included — a type
/// layout and member addresses.
public struct CommentStructureStructFixture {
    public var count: Int
    public var flags: (Int8, Int32)
    public var nested: CommentStructureNestedFixture

    public func memberFixture() {}
}

public struct CommentStructureNestedFixture {
    public var first: Int16
    public var second: Double
}

/// Payload cases of two sizes, so the interface prints an enum layout.
public enum CommentStructureEnumFixture {
    case none
    case count(Int)
    case pair(Int8, Int8)
}

/// Overridable members, so the interface prints vtable offsets.
open class CommentStructureClassFixture {
    open var value: Int = 0

    public init() {}

    open func overridableFixture() {}
}

// MARK: - Tests

/// What the engine sends when a request asks for the comment structure:
/// the printers mark each comment, the engine separates the marks into
/// `RuntimeObjectInterface.commentStructure`, and the text is left exactly
/// as a request without it gets. Swift is covered by the fixtures above,
/// Objective-C by libobjc's `NSObject`, which every system has.
@Suite("Comment structure from the engine", .serialized)
struct RuntimeInterfaceCommentStructureEngineTests {
    private typealias Kind = RuntimeInterfaceCommentStructure.Kind
    private typealias Role = RuntimeInterfaceCommentStructure.Role

    /// This test bundle's image, where every Swift fixture is declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private static let fixtureNames: Set<String> = [
        "CommentStructureStructFixture",
        "CommentStructureNestedFixture",
        "CommentStructureEnumFixture",
        "CommentStructureClassFixture",
    ]

    /// One engine for the suite, and the objects it prints: the Swift
    /// fixtures and `NSObject`.
    private static let shared = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeInterfaceCommentStructureEngineTests")
        try await engine.connect()
        try await engine.loadImage(at: libobjcPath)
        let swiftFixtures = try await engine.objects(in: testBundlePath).filter { object in
            object.kind.isSwift && fixtureNames.contains { object.displayName == $0 || object.displayName.hasSuffix(".\($0)") }
        }
        let nsObject = try await engine.objects(in: libobjcPath).filter { $0.kind == .objc(.type(.class)) && $0.name == "NSObject" }
        return (engine, swiftFixtures + nsObject)
    }

    /// Every comment either language prints, under the options a request
    /// for the structure is made with or without.
    private static func options(marksCommentStructure: Bool) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions(
            objcHeaderOptions: ObjCGenerationOptions(
                addIvarOffsetComments: true,
                addPropertyAttributesComments: true,
                addMethodIMPAddressComments: true,
                addPropertyAccessorAddressComments: true
            ),
            swiftInterfaceOptions: SwiftGenerationOptions(
                printStrippedSymbolicItem: true,
                printFieldOffset: true,
                printExpandedFieldOffset: true,
                printVTableOffset: true,
                printPWTOffset: true,
                printMemberAddress: true,
                printTypeLayout: true,
                printEnumLayout: true,
                synthesizeOpaqueType: true,
                memberSortOrder: .byCategory,
                infersObjCOverridesFromSelectorNames: true
            )
        )
        options.marksCommentStructure = marksCommentStructure
        return options
    }

    /// The kinds and roles `RuntimeInterfaceCommentStructure` names. A
    /// producer that starts printing one more is not wrong, but the content
    /// pane draws it as a plain tag until someone looks — which this list
    /// makes someone do.
    private static let knownKinds: Set<Kind> = [
        .memberAddress, .vtableOffset, .pwtOffset, .fieldOffset, .fieldOffsetUnknown, .fieldLayoutNode,
        .typeLayout, .typeLayoutElement, .enumLayoutSummary, .enumLayoutCase, .enumLayoutCaseHeader,
        .enumLayoutCaseEncoding, .enumLayoutCaseNote, .enumLayoutCaseFixedBytes, .enumLayoutCaseByte,
        .exportStatus, .protocolExtensionDefault, .privateDeclarationSource, .conditionalWitness,
        .conditionalWitnessBranch, .strippedSymbolicRequirement,
        .impAddress, .ivarOffset, .ivarOffsetUnknown, .propertySynthesis, .propertyDynamic, .typeNote,
        .note,
    ]

    private static let knownRoles: Set<Role> = [
        .marker, .label, .qualifier, .separator, .key, .value, .name, .type, .treePrefix, .text,
    ]

    private static func interfaces(marksCommentStructure: Bool) async throws -> [(object: RuntimeObject, interface: RuntimeObjectInterface)] {
        let (engine, objects) = try await shared.value
        var interfaces: [(object: RuntimeObject, interface: RuntimeObjectInterface)] = []
        for object in objects {
            let interface = try #require(try await engine.interface(for: object, options: options(marksCommentStructure: marksCommentStructure)), "no interface for \(object.displayName)")
            interfaces.append((object, interface))
        }
        return interfaces
    }

    /// Where each `//` or `/*` comment of `text` starts, in UTF-8 bytes: the
    /// first one on each line. None of the printed objects has a string that
    /// holds either.
    private static func commentStartOffsets(in text: String) -> [Int] {
        var offsets: [Int] = []
        var lineStart = 0
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let bytes = Array(line)
            if let index = bytes.indices.dropLast().first(where: { bytes[$0] == UInt8(ascii: "/") && (bytes[$0 + 1] == UInt8(ascii: "/") || bytes[$0 + 1] == UInt8(ascii: "*")) }) {
                offsets.append(lineStart + index)
            }
            lineStart += bytes.count + 1
        }
        return offsets
    }

    @Test("the fixtures are listed, and NSObject is")
    func objectsArePrinted() async throws {
        let (_, objects) = try await Self.shared.value
        #expect(objects.count == Self.fixtureNames.count + 1, "\(objects.map(\.displayName))")
    }

    @Test("asking for the structure leaves the text, spans and identifiers as a request without it gets them")
    func textIsTheSameEitherWay() async throws {
        let plainInterfaces = try await Self.interfaces(marksCommentStructure: false)
        let markedInterfaces = try await Self.interfaces(marksCommentStructure: true)
        for (plain, marked) in zip(plainInterfaces, markedInterfaces) {
            #expect(plain.interface.commentStructure == nil, "\(plain.object.displayName)")
            #expect(marked.interface.commentStructure?.isEmpty == false, "\(marked.object.displayName)")
            #expect(marked.interface.interfaceString.string == plain.interface.interfaceString.string, "\(marked.object.displayName)")
            #expect(marked.interface.interfaceString == plain.interface.interfaceString, "\(marked.object.displayName): same text, different spans or identifiers")
        }
    }

    @Test("every comment the text holds lies in one the structure lists, which starts at its marker")
    func everyCommentIsListed() async throws {
        for (object, interface) in try await Self.interfaces(marksCommentStructure: true) {
            let structure = try #require(interface.commentStructure)
            let text = interface.interfaceString.string
            let utf8 = Array(text.utf8)
            let outermostRanges = structure.comments.filter { $0.enclosingCommentIndex == nil }.map(\.utf8Range)
            for range in outermostRanges {
                let opening = String(decoding: utf8[range.lowerBound ..< min(range.lowerBound + 2, utf8.count)], as: UTF8.self)
                #expect(opening == "//" || opening == "/*", "\(object.displayName): a comment starts with \(opening.debugDescription)")
            }
            for offset in Self.commentStartOffsets(in: text) {
                #expect(outermostRanges.contains { $0.contains(offset) }, "\(object.displayName): the comment at byte \(offset) is in none: \(String(decoding: utf8[offset...].prefix(60), as: UTF8.self))")
            }
        }
    }

    @Test("each comment lies in the text and inside the one enclosing it, and each segment inside its comment")
    func rangesNest() async throws {
        for (object, interface) in try await Self.interfaces(marksCommentStructure: true) {
            let structure = try #require(interface.commentStructure)
            let textLength = interface.interfaceString.string.utf8.count
            for (index, comment) in structure.comments.enumerated() {
                #expect(comment.utf8Range.lowerBound >= 0 && comment.utf8Range.upperBound <= textLength, "\(object.displayName)")
                if let enclosingIndex = comment.enclosingCommentIndex {
                    #expect(enclosingIndex < index, "\(object.displayName): a comment is listed before the one enclosing it")
                    let enclosingRange = structure.comments[enclosingIndex].utf8Range
                    #expect(enclosingRange.lowerBound <= comment.utf8Range.lowerBound && comment.utf8Range.upperBound <= enclosingRange.upperBound, "\(object.displayName)")
                }
            }
            for segment in structure.segments {
                let commentRange = structure.comments[segment.commentIndex].utf8Range
                #expect(commentRange.lowerBound <= segment.utf8Range.lowerBound && segment.utf8Range.upperBound <= commentRange.upperBound, "\(object.displayName)")
            }
        }
    }

    @Test("the kinds and roles are ones RuntimeViewer names, and each option's comments are there")
    func kindsAreKnownAndPresent() async throws {
        var seenKinds: Set<Kind> = []
        var seenRoles: Set<Role> = []
        for (_, interface) in try await Self.interfaces(marksCommentStructure: true) {
            let structure = try #require(interface.commentStructure)
            seenKinds.formUnion(structure.comments.map(\.kind))
            seenRoles.formUnion(structure.segments.map(\.role))
        }
        #expect(seenKinds.isSubset(of: Self.knownKinds), "unknown kinds: \(seenKinds.subtracting(Self.knownKinds).map(\.rawValue).sorted())")
        #expect(seenRoles.isSubset(of: Self.knownRoles), "unknown roles: \(seenRoles.subtracting(Self.knownRoles).map(\.rawValue).sorted())")
        let expectedKinds: [Kind] = [
            .memberAddress, .vtableOffset, .fieldOffset, .fieldLayoutNode, .typeLayout,
            .enumLayoutSummary, .enumLayoutCase,
            .impAddress, .ivarOffset,
        ]
        for kind in expectedKinds {
            #expect(seenKinds.contains(kind), "no \(kind.rawValue) comment among \(seenKinds.map(\.rawValue).sorted())")
        }
    }
}

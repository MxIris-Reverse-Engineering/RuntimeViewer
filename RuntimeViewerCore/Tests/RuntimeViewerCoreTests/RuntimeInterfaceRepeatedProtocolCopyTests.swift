import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// An Objective-C protocol two images carry alike is one declaration: a
/// search over both reports it once, from the image it reads first, and
/// counts what it leaves out. Copies that read differently — an image built
/// against an older header — keep their own hits.
@Suite("Repeated Objective-C protocol copies", .serialized)
struct RuntimeInterfaceRepeatedProtocolCopyTests {
    // MARK: - Scripted corpora

    private static let firstImagePath = "/Images/A"
    private static let secondImagePath = "/Images/B"

    /// One object of a scripted image: its name, kind, interface text,
    /// visibility regions and members, located by the store's assembly.
    struct ScriptedObject: Sendable {
        let name: String
        let kind: RuntimeObjectKind
        let interface: FrozenSemanticString
        let visibilityRegions: VisibilityRegionTable
        let members: [RuntimeMemberDeclaration]
    }

    final class ScriptedBuilder: RuntimeInterfaceCorpusBuilding, @unchecked Sendable {
        let objectsByImagePath: [String: [ScriptedObject]]

        init(objectsByImagePath: [String: [ScriptedObject]]) {
            self.objectsByImagePath = objectsByImagePath
        }

        func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
            (objectsByImagePath[imagePath] ?? []).map { object in
                RuntimeObject(name: object.name, displayName: object.name, kind: object.kind, imagePath: imagePath, children: [])
            }
        }

        func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome] {
            family.map { object in
                guard let scripted = objectsByImagePath[object.imagePath]?.first(where: { $0.name == object.name }) else { return .empty }
                return .printed(RuntimeInterfaceCorpusPrint(
                    object: object,
                    interface: scripted.interface,
                    visibilityRegions: scripted.visibilityRegions,
                    members: scripted.members,
                    nestedDefinitionRanges: []
                ))
            }
        }
    }

    /// `@protocol NSCopying` declaring `copyWithZone:` and, when given,
    /// `extraMethodName` too; a comment the Generation Options decide follows
    /// `copyWithZone:` when `addressComment` is given.
    private static func copyingProtocol(extraMethodName: String? = nil, addressComment: String? = nil) -> ScriptedObject {
        var interface = SemanticString {
            Keyword("@protocol")
            Standard(" ")
            TypeDeclaration(kind: .protocol, "NSCopying")
            Standard("\n- (")
            Keyword("id")
            Standard(")")
            FunctionDeclaration("copyWithZone")
            Standard(":(")
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, "_NSZone")
            Standard(" *)")
            Argument("zone")
            Standard(";")
        }
        var regions: [VisibilityRegionTable.Region] = []
        if let addressComment {
            let offset = interface.string.utf8.count
            let comment = SemanticString { Standard(" "); Comment(addressComment) }
            interface.append(comment)
            regions.append(VisibilityRegionTable.Region(utf8Offset: UInt32(offset), utf8Length: UInt32(comment.string.utf8.count), conditionIndex: 0))
        }
        var members = [RuntimeMemberDeclaration(name: "copyWithZone:", kind: .objcMethod, isStatic: false, declarationText: "copyWithZone:", lineNumber: nil)]
        if let extraMethodName {
            interface.append(SemanticString {
                Standard("\n- (")
                Keyword("void")
                Standard(")")
                FunctionDeclaration(extraMethodName)
                Standard(";")
            })
            members.append(RuntimeMemberDeclaration(name: extraMethodName, kind: .objcMethod, isStatic: false, declarationText: extraMethodName, lineNumber: nil))
        }
        interface.append(SemanticString { Standard("\n"); Keyword("@end") })
        return ScriptedObject(
            name: "NSCopying",
            kind: .objc(.type(.protocol)),
            interface: interface.frozen(),
            visibilityRegions: regions.isEmpty ? .empty : VisibilityRegionTable(regions: regions, conditions: [.enabled("objc.addMethodIMPAddressComments")]),
            members: members
        )
    }

    /// An Objective-C class that only declares `copyWithZone:`.
    private static func copyingClass() -> ScriptedObject {
        ScriptedObject(
            name: "Copier",
            kind: .objc(.type(.class)),
            interface: SemanticString {
                Keyword("@interface")
                Standard(" ")
                TypeDeclaration(kind: .class, "Copier")
                Standard("\n- (")
                Keyword("id")
                Standard(")")
                FunctionDeclaration("copyWithZone")
                Standard(":(")
                Keyword("id")
                Standard(")")
                Argument("zone")
                Standard(";\n")
                Keyword("@end")
            }.frozen(),
            visibilityRegions: .empty,
            members: [RuntimeMemberDeclaration(name: "copyWithZone:", kind: .objcMethod, isStatic: false, declarationText: "copyWithZone:", lineNumber: nil)]
        )
    }

    private struct SearchOutcome {
        var textImagePaths: [String] = []
        var textSummary: RuntimeInterfaceSearchSummary?
        var memberImagePaths: [String] = []
        var memberSummary: RuntimeInterfaceSearchSummary?
    }

    /// Builds both images' corpora and searches them for `copyWithZone` by
    /// text and by member, under `generationOptions`.
    private static func searchForCopyWithZone(in objectsByImagePath: [String: [ScriptedObject]], generationOptions: RuntimeObjectInterface.GenerationOptions? = nil) async throws -> SearchOutcome {
        let builder = ScriptedBuilder(objectsByImagePath: objectsByImagePath)
        let store = RuntimeInterfaceCorpusStore(builder: builder, printingWidth: 1)
        defer { withExtendedLifetime(builder) {} }
        for imagePath in objectsByImagePath.keys.sorted() {
            _ = try await store.build(imagePath: imagePath, transformer: .default)
        }
        var outcome = SearchOutcome()
        var textMatches: [RuntimeInterfaceSearchMatch] = []
        outcome.textSummary = try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "copyWithZone", generationOptions: generationOptions), indexedImagePaths: []) { batch in
            textMatches += batch
        }
        outcome.textImagePaths = textMatches.map(\.object.imagePath)
        var memberMatches: [RuntimeMemberMatch] = []
        outcome.memberSummary = try await store.searchMembers(RuntimeMemberSearchQuery(text: "copyWithZone:", kinds: [.objcMethod], isCaseSensitive: true, generationOptions: generationOptions), indexedImagePaths: []) { batch in
            memberMatches += batch
        }
        outcome.memberImagePaths = memberMatches.map(\.object.imagePath)
        return outcome
    }

    @Test("a protocol two images carry alike is reported once, from the image read first, by text and by member")
    func identicalCopiesReportedOnce() async throws {
        let outcome = try await Self.searchForCopyWithZone(in: [
            Self.secondImagePath: [Self.copyingProtocol()],
            Self.firstImagePath: [Self.copyingProtocol()],
        ])
        #expect(outcome.textImagePaths == [Self.firstImagePath])
        #expect(outcome.textSummary?.totalMatchCount == 1)
        #expect(outcome.textSummary?.omittedRepeatedMatchCount == 1)
        #expect(outcome.textSummary?.isTruncated == false)
        #expect(outcome.memberImagePaths == [Self.firstImagePath])
        #expect(outcome.memberSummary?.totalMatchCount == 1)
        #expect(outcome.memberSummary?.omittedRepeatedMatchCount == 1)
    }

    @Test("copies that read alike only under the search's options are folded under those options")
    func copiesAlikeUnderTheOptionsFolded() async throws {
        let objectsByImagePath = [
            Self.firstImagePath: [Self.copyingProtocol(addressComment: "IMP: 0x1000")],
            Self.secondImagePath: [Self.copyingProtocol(addressComment: "IMP: 0x2000")],
        ]
        // The defaults hide the address comments, the only difference.
        let underDefaults = try await Self.searchForCopyWithZone(in: objectsByImagePath, generationOptions: RuntimeObjectInterface.GenerationOptions())
        #expect(underDefaults.textImagePaths == [Self.firstImagePath])
        #expect(underDefaults.textSummary?.omittedRepeatedMatchCount == 1)
        #expect(underDefaults.memberImagePaths == [Self.firstImagePath])
        #expect(underDefaults.memberSummary?.omittedRepeatedMatchCount == 1)
        // With everything shown they read differently, so both are reported.
        let underEverything = try await Self.searchForCopyWithZone(in: objectsByImagePath)
        #expect(underEverything.textImagePaths == [Self.firstImagePath, Self.secondImagePath])
        #expect(underEverything.memberImagePaths == [Self.firstImagePath, Self.secondImagePath])
    }

    @Test("copies that read differently each keep their hits")
    func differingCopiesKeepTheirHits() async throws {
        let outcome = try await Self.searchForCopyWithZone(in: [
            Self.firstImagePath: [Self.copyingProtocol()],
            Self.secondImagePath: [Self.copyingProtocol(extraMethodName: "copyWithoutZone")],
        ])
        #expect(outcome.textImagePaths == [Self.firstImagePath, Self.secondImagePath])
        #expect(outcome.textSummary?.totalMatchCount == 2)
        #expect(outcome.textSummary?.omittedRepeatedMatchCount == 0)
        #expect(outcome.memberImagePaths == [Self.firstImagePath, Self.secondImagePath])
        #expect(outcome.memberSummary?.totalMatchCount == 2)
        #expect(outcome.memberSummary?.omittedRepeatedMatchCount == 0)
    }

    @Test("classes that read alike are not folded: only a protocol is copied into every image that saw it")
    func identicalClassesKeepTheirHits() async throws {
        let outcome = try await Self.searchForCopyWithZone(in: [
            Self.firstImagePath: [Self.copyingClass()],
            Self.secondImagePath: [Self.copyingClass()],
        ])
        #expect(outcome.textImagePaths == [Self.firstImagePath, Self.secondImagePath])
        #expect(outcome.memberImagePaths == [Self.firstImagePath, Self.secondImagePath])
    }

    // MARK: - Real images

    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    @Test("NSCopying, which CoreFoundation and Foundation both carry, is reported once by text and by member")
    func repeatedCopyReportedOnceAcrossRealImages() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-repeated-protocol-copies")
        try await engine.connect()
        for imagePath in [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath] {
            try await engine.loadImage(at: imagePath)
        }
        for imagePath in [Anchors.coreFoundationPath, Anchors.foundationPath] {
            _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default)
        }
        let options = RuntimeObjectInterface.GenerationOptions()
        let isCopyingProtocol: (RuntimeObject) -> Bool = { $0.kind == .objc(.type(.protocol)) && $0.name == "NSCopying" }

        // Both carry `NSCopying`, and it reads alike in both under these
        // options; if the system changes that, say so instead of passing.
        let visibility = RuntimeInterfaceVisibility(options)
        var shownTexts: [String] = []
        for imagePath in [Anchors.coreFoundationPath, Anchors.foundationPath] {
            let entries = try #require(await engine.interfaceCorpusStore.corpus(for: imagePath)?.entries)
            let copy = try #require(entries.first { isCopyingProtocol($0.object) }, "\(imagePath) no longer carries NSCopying")
            shownTexts.append((copy.projection(under: visibility)?.text ?? copy.interface).text)
        }
        try #require(shownTexts[0] == shownTexts[1], "the two copies of NSCopying no longer read alike")

        var textMatches: [RuntimeInterfaceSearchMatch] = []
        let textSummary = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(text: "copyWithZone", generationOptions: options)) { batch in
            textMatches += batch
        }
        let textImagePaths = Set(textMatches.filter { isCopyingProtocol($0.object) }.map(\.object.imagePath))
        #expect(textImagePaths == [Anchors.coreFoundationPath], "NSCopying reported from \(textImagePaths)")
        #expect(textSummary.omittedRepeatedMatchCount > 0)

        var memberMatches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "copyWithZone:", kinds: [.objcMethod], isCaseSensitive: true, generationOptions: options)) { batch in
            memberMatches += batch
        }
        let memberImagePaths = Set(memberMatches.filter { isCopyingProtocol($0.object) }.map(\.object.imagePath))
        #expect(memberImagePaths == [Anchors.coreFoundationPath], "NSCopying reported from \(memberImagePaths)")
        await engine.stop()
    }
}

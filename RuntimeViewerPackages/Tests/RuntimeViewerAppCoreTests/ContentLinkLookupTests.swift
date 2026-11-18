import Foundation
import Testing
import Semantic
import RuntimeViewerCore
import RuntimeViewerCrossReferences
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The content panes ask what is at a character index for their right-click menu, their ⌘-click and
/// their insertion point. They look it up in the interface's tables (proposal
/// `app-core-without-ui-models`) — the attributed string they used to read it off carried them as
/// attributes — and AppKit hands them the insertion point's index, which is the text's length after
/// its last character: a click below the last line, or in an empty or still loading pane. The lookups
/// answer nothing there.
@Suite("Looking up links and declared members in the content pane's interface")
struct ContentLinkLookupTests {
    private static let owner = Fixtures.runtimeObject(name: "SampleOwner", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    private static let linkedObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    private static let member = RuntimeMemberReference(object: owner, name: "run", kind: .objcMethod, isStatic: false)

    /// `class NSObject` on the first line, `- (void)run;` on the second.
    private static func interface() -> ContentInterface {
        let semanticString = SemanticString {
            Standard("class ")
            TypeName(kind: .class, "NSObject")
            Standard("\n- (void)run;")
        }
        .frozen()
        return ContentInterface(
            runtimeObject: owner,
            semanticString: semanticString,
            links: [ContentInterface.Link(range: NSRange(location: 6, length: 8), target: linkedObject)],
            declaredMemberLines: [ContentInterface.DeclaredMemberLine(range: NSRange(location: 15, length: 12), member: member)]
        )
    }

    @Test("an Objective-C interface links each type token to the class it names, over the token")
    func objectiveCTypeTokenLinksToItsClass() throws {
        let links = ContentInterface.links(in: Self.interface().semanticString, of: Self.owner)

        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.range == NSRange(location: 6, length: 8))
        #expect(link.target.name == "NSObject")
        #expect(link.target.kind == .objc(.type(.class)))
        #expect(link.target.imagePath == Self.owner.imagePath)
    }

    @Test("a link and a declared member are looked up by UTF-16 offset")
    func linkedRuntimeObjectAndDeclaredMemberLookUpByUTF16Offset() {
        let interface = Self.interface()

        #expect(interface.linkedRuntimeObject(at: 6) == Self.linkedObject)
        #expect(interface.linkedRuntimeObject(at: 13) == Self.linkedObject)
        #expect(interface.linkedRuntimeObject(at: 5) == nil)
        #expect(interface.linkedRuntimeObject(at: 14) == nil)
        #expect(interface.declaredMember(at: 15) == Self.member)
        #expect(interface.declaredMember(at: 26) == Self.member)
        #expect(interface.declaredMember(at: 7) == nil)
    }

    @Test("asking past the end of the text, or before its start, answers nothing")
    func lookupsOutOfBoundsReturnNil() {
        let interface = Self.interface()
        let length = (interface.string as NSString).length

        #expect(interface.linkedRuntimeObject(at: length) == nil)
        #expect(interface.declaredMember(at: length) == nil)
        #expect(interface.linkedRuntimeObject(at: -1) == nil)
        let emptyInterface = ContentInterface(runtimeObject: Self.owner, semanticString: ("" as SemanticString).frozen(), links: [], declaredMemberLines: [])
        #expect(emptyInterface.linkedRuntimeObject(at: 0) == nil)
        #expect(emptyInterface.declaredMember(at: 0) == nil)
    }
}

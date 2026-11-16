#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The content panes ask what is at a character index for their right-click
/// menu and their insertion point, and AppKit hands them the insertion point's
/// index — which is the text's length after its last character: a click below
/// the last line, or in an empty or still loading pane. Asking an attributed
/// string for an attribute there raises `NSRangeException` and ends the app,
/// so the lookups answer nothing instead.
@Suite("Looking up links in the content pane's text")
struct ContentLinkLookupTests {
    private static let linkedObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    private static func text() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "class NSObject")
        text.addAttribute(.link, value: linkedObject, range: NSRange(location: 6, length: 8))
        return text
    }

    @Test("a token's link is the object it names")
    func linkInsideTheText() {
        #expect(Self.text().linkedRuntimeObject(at: 7) == Self.linkedObject)
        #expect(Self.text().linkedRuntimeObject(at: 0) == nil)
        #expect(Self.text().declaredMember(at: 0) == nil)
    }

    /// The text a text view hands over is its text storage, which — like any
    /// mutable attributed string, and unlike an immutable one — raises for an
    /// index at its end. Run in a process of its own: before the fix the
    /// lookup raised, which takes the whole test process down.
    @Test("asking past the end of a text view's text answers nothing")
    func lookupPastTheEnd() async {
        await #expect(processExitsWith: .success) {
            let storage = NSTextStorage(string: "class NSObject")
            let emptyStorage = NSTextStorage(string: "")
            let mutableText = NSMutableAttributedString(string: "class NSObject")
            let answers: [Bool] = [
                storage.linkedRuntimeObject(at: storage.length) == nil,
                storage.declaredMember(at: storage.length) == nil,
                emptyStorage.linkedRuntimeObject(at: 0) == nil,
                emptyStorage.declaredMember(at: 0) == nil,
                mutableText.linkedRuntimeObject(at: mutableText.length) == nil,
            ]
            exit(answers.allSatisfy { $0 } ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }
}

import AppKit
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// How a Find result the user chose opens, read off the event that chose it: ⌥ opens it in the next
/// editor pane and ⇧⌥ in a new tab (proposal `option-click-next-editor-pane`), and a typed character
/// is type-select, which the page waits out before it navigates.
@Suite("Find result activation")
@MainActor
struct FindResultActivationTests {
    private static func mouseUp(with modifierFlags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    private static func keyDown(characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    @Test("⌥ opens the chosen result in the next editor pane, ⇧⌥ in a new tab; a plain click, ⇧ alone and no event in the focused tab")
    func modifiersPickTheDestination() throws {
        #expect(FindResultActivation.destination(for: try Self.mouseUp(with: .option)) == .nextEditorPane)
        #expect(FindResultActivation.destination(for: try Self.mouseUp(with: [.option, .shift])) == .newTab)
        #expect(FindResultActivation.destination(for: try Self.mouseUp(with: [])) == .focusedTab)
        #expect(FindResultActivation.destination(for: try Self.mouseUp(with: .shift)) == .focusedTab)
        #expect(FindResultActivation.destination(for: nil) == .focusedTab)
    }

    @Test("on a type link ⇧ alone opens a new tab too, as ⇧⌘-click always has")
    func linkClicksTakeShiftForANewTab() {
        #expect(SelectionRoute.Destination(linkClickModifierFlags: [.command]) == .focusedTab)
        #expect(SelectionRoute.Destination(linkClickModifierFlags: [.command, .shift]) == .newTab)
        #expect(SelectionRoute.Destination(linkClickModifierFlags: [.command, .option]) == .nextEditorPane)
        #expect(SelectionRoute.Destination(linkClickModifierFlags: [.command, .option, .shift]) == .newTab)
    }

    @Test("a typed character is type-select; a click, an arrow key and no event are not")
    func typedCharacterIsTypeSelect() throws {
        #expect(FindResultActivation.isTypeSelect(try Self.keyDown(characters: "n", keyCode: 45)))
        #expect(!FindResultActivation.isTypeSelect(try Self.keyDown(characters: "\u{F701}", keyCode: 125)))
        #expect(!FindResultActivation.isTypeSelect(try Self.mouseUp(with: [])))
        #expect(!FindResultActivation.isTypeSelect(nil))
    }

    @Test("type-select matches a row by the text it starts with")
    func typeSelectReadsTheRowsText() throws {
        let type = FindResultFixtures.type(FindResultFixtures.object(named: "Alpha"), hits: [
            FindResultFixtures.hit(in: "Alpha", lineNumber: 1, lineText: "    - (void)indented;"),
        ])

        #expect(type.typeSelectString == "Alpha")
        #expect(try #require(type.children.first).typeSelectString == "- (void)indented;")
    }
}

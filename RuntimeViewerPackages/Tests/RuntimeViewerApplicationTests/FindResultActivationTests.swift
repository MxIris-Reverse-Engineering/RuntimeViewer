import AppKit
import Testing
@testable import RuntimeViewerApplication

/// How a Find result the user chose opens, read off the event that chose it: ⌥ opens it in a new
/// tab (proposal `0029-find-navigator` §4, missing until PR121.07), and a typed character is
/// type-select, which the page waits out before it navigates.
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

    @Test("⌥ opens the chosen result in a new tab; a plain click and no event do not")
    func optionOpensInNewTab() throws {
        #expect(FindResultActivation.opensInNewTab(for: try Self.mouseUp(with: .option)))
        #expect(!FindResultActivation.opensInNewTab(for: try Self.mouseUp(with: [])))
        #expect(!FindResultActivation.opensInNewTab(for: nil))
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

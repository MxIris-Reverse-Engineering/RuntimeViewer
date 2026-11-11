import AppKit
import Testing
import RuntimeViewerUI

/// The keys a list page gives a meaning of its own, and the outline handing them to the page
/// first (draft-keyboard-commands).
@Suite("List key presses")
@MainActor
struct ListKeyPressTests {
    @Test("Return and the keypad's Enter are Return presses, but not with a modifier")
    func returnKeyPresses() throws {
        #expect(try Self.keyPress(keyCode: 36, characters: "\r").isReturnKeyPress)
        #expect(try Self.keyPress(keyCode: 76, characters: "\u{3}", modifierFlags: .numericPad).isReturnKeyPress)
        #expect(try !Self.keyPress(keyCode: 36, characters: "\r", modifierFlags: .option).isReturnKeyPress)
        #expect(try !Self.keyPress(keyCode: 51, characters: "\u{7F}").isReturnKeyPress)
    }

    @Test("Delete and Forward Delete are Delete presses, but not with a modifier")
    func deleteKeyPresses() throws {
        #expect(try Self.keyPress(keyCode: 51, characters: "\u{7F}").isDeleteKeyPress)
        #expect(try Self.keyPress(keyCode: 117, characters: String(Character(UnicodeScalar(NSDeleteFunctionKey)!)), modifierFlags: .function).isDeleteKeyPress)
        #expect(try !Self.keyPress(keyCode: 51, characters: "\u{7F}", modifierFlags: .command).isDeleteKeyPress)
        #expect(try !Self.keyPress(keyCode: 36, characters: "\r").isDeleteKeyPress)
    }

    @Test("the outline offers each key press to its handler first")
    func outlineOffersKeyPressesToItsHandler() throws {
        let outlineView = StatefulOutlineView()
        var offeredKeyCodes: [UInt16] = []
        outlineView.keyDownHandler = { event in
            offeredKeyCodes.append(event.keyCode)
            return event.isReturnKeyPress
        }

        outlineView.keyDown(with: try Self.keyPress(keyCode: 36, characters: "\r"))

        #expect(offeredKeyCodes == [36])
    }

    private static func keyPress(keyCode: UInt16, characters: String, modifierFlags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

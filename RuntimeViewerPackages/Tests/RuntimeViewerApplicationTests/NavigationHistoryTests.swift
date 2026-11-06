import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// `NavigationHistory` is what one tab has shown, the list back and forward walk.
@Suite("NavigationHistory")
struct NavigationHistoryTests {
    private let firstObject = Fixtures.runtimeObject(name: "First")
    private let secondObject = Fixtures.runtimeObject(name: "Second")
    private let thirdObject = Fixtures.runtimeObject(name: "Third")

    private func historyOfThree() -> NavigationHistory {
        var history = NavigationHistory()
        history.record(firstObject)
        history.record(secondObject)
        history.record(thirdObject)
        return history
    }

    @Test("a tab that has shown nothing has no current entry and cannot move")
    func emptyHistory() {
        let history = NavigationHistory()

        #expect(history.currentEntry == nil)
        #expect(!history.canGoBackward)
        #expect(!history.canGoForward)
    }

    @Test("each object shown is appended and becomes the current entry")
    func recordingAppends() {
        let history = historyOfThree()

        #expect(history.entries == [firstObject, secondObject, thirdObject])
        #expect(history.currentEntry == thirdObject)
        #expect(history.canGoBackward)
        #expect(!history.canGoForward)
    }

    @Test("showing something new from the middle drops the entries after it")
    func recordingFromTheMiddleDropsTheFuture() {
        var history = historyOfThree()
        history.goBackward()
        history.goBackward()
        let otherObject = Fixtures.runtimeObject(name: "Other")

        history.record(otherObject)

        #expect(history.entries == [firstObject, otherObject])
        #expect(history.currentEntry == otherObject)
    }

    @Test("showing the last entry again in another form keeps one entry, in the new form")
    func recordingTheSameTypeTakesTheNewForm() throws {
        var history = historyOfThree()
        let renamedThirdObject = Fixtures.runtimeObject(name: "Third", displayName: "Module.Third")

        history.record(renamedThirdObject)

        #expect(history.entries.count == 3)
        #expect(try #require(history.currentEntry).displayName == "Module.Third")
    }

    @Test("going backward and forward moves the current entry and stops at both ends")
    func goingBackwardAndForward() {
        var history = historyOfThree()

        history.goBackward()
        history.goBackward()
        history.goBackward()
        #expect(history.currentEntry == firstObject)
        #expect(!history.canGoBackward)

        history.goForward()
        #expect(history.currentEntry == secondObject)
        #expect(history.canGoForward)
    }

    @Test("jumping moves to the entry at an index and ignores one out of range")
    func jumping() {
        var history = historyOfThree()

        history.go(to: 0)
        #expect(history.currentEntry == firstObject)

        history.go(to: 7)
        #expect(history.currentEntry == firstObject)
        #expect(history.entries.count == 3)
    }

    @Test("resetting leaves the given object alone in the history")
    func resetting() {
        var history = historyOfThree()

        history.reset(to: secondObject)

        #expect(history.entries == [secondObject])
        #expect(history.currentEntry == secondObject)
    }
}

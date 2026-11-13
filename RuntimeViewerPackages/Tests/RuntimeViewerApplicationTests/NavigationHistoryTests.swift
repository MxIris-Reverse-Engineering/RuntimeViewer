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
        history.record(NavigationEntry(object: firstObject))
        history.record(NavigationEntry(object: secondObject))
        history.record(NavigationEntry(object: thirdObject))
        return history
    }

    @Test("a tab that has shown nothing has no current entry and cannot move")
    func emptyHistory() {
        let history = NavigationHistory()

        #expect(history.currentEntry?.object == nil)
        #expect(!history.canGoBackward)
        #expect(!history.canGoForward)
    }

    @Test("each object shown is appended and becomes the current entry")
    func recordingAppends() {
        let history = historyOfThree()

        #expect(history.entries.map(\.object) == [firstObject, secondObject, thirdObject])
        #expect(history.currentEntry?.object == thirdObject)
        #expect(history.canGoBackward)
        #expect(!history.canGoForward)
    }

    @Test("showing something new from the middle drops the entries after it")
    func recordingFromTheMiddleDropsTheFuture() {
        var history = historyOfThree()
        history.goBackward()
        history.goBackward()
        let otherObject = Fixtures.runtimeObject(name: "Other")

        history.record(NavigationEntry(object: otherObject))

        #expect(history.entries.map(\.object) == [firstObject, otherObject])
        #expect(history.currentEntry?.object == otherObject)
    }

    @Test("showing the last entry again in another form keeps one entry, in the new form")
    func recordingTheSameTypeTakesTheNewForm() throws {
        var history = historyOfThree()
        let renamedThirdObject = Fixtures.runtimeObject(name: "Third", displayName: "Module.Third")

        history.record(NavigationEntry(object: renamedThirdObject))

        #expect(history.entries.count == 3)
        #expect(try #require(history.currentEntry).object?.displayName == "Module.Third")
    }

    @Test("going backward and forward moves the current entry and stops at both ends")
    func goingBackwardAndForward() {
        var history = historyOfThree()

        history.goBackward()
        history.goBackward()
        history.goBackward()
        #expect(history.currentEntry?.object == firstObject)
        #expect(!history.canGoBackward)

        history.goForward()
        #expect(history.currentEntry?.object == secondObject)
        #expect(history.canGoForward)
    }

    @Test("jumping moves to the entry at an index and ignores one out of range")
    func jumping() {
        var history = historyOfThree()

        history.go(to: 0)
        #expect(history.currentEntry?.object == firstObject)

        history.go(to: 7)
        #expect(history.currentEntry?.object == firstObject)
        #expect(history.entries.count == 3)
    }

    @Test("resetting leaves the given object alone in the history")
    func resetting() {
        var history = historyOfThree()

        history.reset(to: secondObject)

        #expect(history.entries.map(\.object) == [secondObject])
        #expect(history.currentEntry?.object == secondObject)
    }

    // MARK: - Generated Interface

    @Test("an object's Generated Interface is a step of its own, and going back returns to its header")
    func generatedInterfaceIsAStepOfItsOwn() {
        let objcClass = Fixtures.runtimeObject(name: "NSColor", kind: .objc(.type(.class)))
        var history = NavigationHistory()
        history.record(NavigationEntry(object: objcClass))
        history.record(NavigationEntry(object: objcClass, interfaceLanguage: .swift))
        #expect(history.entries.count == 2)
        #expect(history.currentEntry?.showsGeneratedInterface == true)

        history.goBackward()
        #expect(history.currentEntry == NavigationEntry(object: objcClass))
        #expect(history.currentEntry?.showsGeneratedInterface == false)
    }

    @Test("Generated Interface switches an Objective-C entry to Swift and back; links from it stay in Swift")
    func generatedInterfaceToggleAndLinks() {
        let objcClass = Fixtures.runtimeObject(name: "NSColor", kind: .objc(.type(.class)))
        let swiftClass = Fixtures.runtimeObject(name: "Module.Swifty")
        let header = NavigationEntry(object: objcClass)
        let swiftForm = NavigationEntry(object: objcClass, interfaceLanguage: .swift)
        #expect(header.togglingGeneratedInterface == swiftForm)
        #expect(swiftForm.togglingGeneratedInterface == header)
        #expect(NavigationEntry(object: swiftClass).togglingGeneratedInterface == nil)

        #expect(NavigationEntry.interfaceLanguage(forLinkTo: objcClass, from: .swift) == .swift)
        #expect(NavigationEntry.interfaceLanguage(forLinkTo: swiftClass, from: .swift) == nil)
        #expect(NavigationEntry.interfaceLanguage(forLinkTo: objcClass, from: nil) == nil)
    }

    @Test("opening in a language records it on the focused tab")
    func editorAreaOpensInALanguage() {
        let objcClass = Fixtures.runtimeObject(name: "NSColor", kind: .objc(.type(.class)))
        var editorArea = EditorArea()
        editorArea.open(objcClass, in: .focusedTab)
        editorArea.open(objcClass, in: .focusedTab, interfaceLanguage: .swift)
        let activeTab = editorArea.focusedPane.activeTab
        #expect(activeTab.history.entries.count == 2)
        #expect(activeTab.object == objcClass)
        #expect(activeTab.interfaceLanguage == .swift)
    }

    // MARK: - Images

    @Test("an image entry is named after the image's file, has no object and no Generated Interface")
    func imageEntry() {
        let imageEntry = NavigationEntry(imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")

        #expect(imageEntry.displayName == "AppKit")
        #expect(imageEntry.object == nil)
        #expect(imageEntry.interfaceLanguage == nil)
        #expect(imageEntry.imagePath == "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
        #expect(imageEntry.showsGeneratedInterface == false)
        #expect(imageEntry.togglingGeneratedInterface == nil)
        #expect(NavigationEntry(object: firstObject).imagePath == nil)
    }

    @Test("an image is a step between objects, and recording it again only moves to it")
    func imageIsAStep() {
        var history = NavigationHistory()
        history.record(NavigationEntry(object: firstObject))
        history.record(NavigationEntry(imagePath: Fixtures.sampleImagePath))
        history.record(NavigationEntry(imagePath: Fixtures.sampleImagePath))
        history.record(NavigationEntry(object: secondObject))

        #expect(history.entries.map(\.displayName) == ["First", "Sample", "Second"])
        history.goBackward()
        #expect(history.currentEntry?.imagePath == Fixtures.sampleImagePath)
        #expect(history.currentEntry?.object == nil)
    }
}

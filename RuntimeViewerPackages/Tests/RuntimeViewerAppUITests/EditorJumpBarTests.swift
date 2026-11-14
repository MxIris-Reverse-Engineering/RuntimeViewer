import AppKit
import AppKitPlus
import Foundation
import Testing
import RxSwift
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerAppUI

/// The tree an editor pane's jump bar walks, and the adapter that puts it on AppKitPlus's
/// `NSPopUpPathControl` (proposal `editor-jump-bar`). The engine is a real in-process one; the
/// control is a real one, off screen. A choice is made the way the control makes one — it selects
/// the chosen row's item, then tells its delegate — because a menu's tracking loop cannot run in a
/// test.
@Suite("Editor jump bar")
@MainActor
struct EditorJumpBarTests {
    // MARK: - Fixtures

    /// A document on `engine` and a store following it, once the engine's image tree is in it.
    private func makeStore(on engine: RuntimeEngine) async throws -> (ViewModelTestEnvironment, EditorJumpBarItemStore) {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let store = environment.make { EditorJumpBarItemStore(documentState: environment.documentState) }
        let hasTree = await pollUntil(timeout: .seconds(15)) {
            guard let sourceItem = store.rootItems.first else { return false }
            return !(store.childItems(of: sourceItem) ?? []).isEmpty
        }
        #expect(hasTree, "the engine never published an image tree")
        return (environment, store)
    }

    private static func object(named name: String, in imagePath: String, of engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: imagePath)
        guard let object = objects.first(where: { $0.name == name && $0.kind == .objc(.type(.class)) }) else {
            throw MissingRuntimeObject(name: name, imagePath: imagePath)
        }
        return object
    }

    /// The names of the items from the top of the tree down to `item`.
    private static func pathNames(to item: EditorJumpBarItem) -> [String] {
        var names: [String] = []
        var currentItem: (any NSPopUpPathItem)? = item
        while let pathItem = currentItem {
            names.insert(pathItem.pathComponentName, at: 0)
            currentItem = pathItem.parentItem
        }
        return names
    }

    private static func childItems(of item: EditorJumpBarItem) -> [EditorJumpBarItem]? {
        item.childItems?.compactMap { $0 as? EditorJumpBarItem }
    }

    // MARK: - The tree

    @Test("the path to an object runs from the engine down the image tree to its image, then the object")
    func pathToAnObject() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let nsObject = try await Self.object(named: "NSObject", in: TestImages.libobjc, of: engine)

        let objectItem = try #require(store.item(for: .object(nsObject)))

        let names = Self.pathNames(to: objectItem)
        #expect(names.first == engine.source.description)
        #expect(Array(names.suffix(4)) == ["usr", "lib", "libobjc.A.dylib", "NSObject"])
        let imageItem = try #require(objectItem.parentItem as? EditorJumpBarItem)
        #expect(imageItem.representsDocumentRoot)
        #expect(!imageItem.isLeaf, "an image leads to its objects, so the path after it ends in No Selection")
        #expect(store.rootItems.first === Self.topItem(of: objectItem))
    }

    private static func topItem(of item: EditorJumpBarItem) -> EditorJumpBarItem {
        var topItem = item
        while let parentItem = topItem.parentItem as? EditorJumpBarItem {
            topItem = parentItem
        }
        return topItem
    }

    @Test("an image's objects become its children once read, in the sidebar's order, a separator between kinds")
    func imageObjectsInSidebarOrder() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }

        let imageItem = try #require(store.item(for: .image(path: TestImages.libobjc)))
        let didRead = await pollUntil(timeout: .seconds(15)) { imageItem.childItems != nil }
        #expect(didRead)

        let childItems = try #require(Self.childItems(of: imageItem))
        let expectedObjects = EditorJumpBarItemStore.menuOrder(of: try await engine.objects(in: TestImages.libobjc))
        #expect(childItems.map(\.pathComponentName) == expectedObjects.map(\.displayName))
        let startsNewGroup = zip(childItems.dropFirst(), childItems).map { $0.groupIdentifier != $1.groupIdentifier }
        let startsNewKind = zip(expectedObjects.dropFirst(), expectedObjects).map { $0.kind != $1.kind }
        #expect(startsNewGroup == startsNewKind)
    }

    @Test("an object asked for before its image's objects were read keeps its item once they are")
    func objectKeepsItsItem() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let nsObject = try await Self.object(named: "NSObject", in: TestImages.libobjc, of: engine)

        let itemBeforeReading = try #require(store.item(for: .object(nsObject)))
        let imageItem = try #require(itemBeforeReading.parentItem as? EditorJumpBarItem)
        let didRead = await pollUntil(timeout: .seconds(15)) { imageItem.childItems != nil }
        #expect(didRead)

        #expect(store.item(for: .object(nsObject)) === itemBeforeReading)
        #expect(Self.childItems(of: imageItem)?.contains { $0 === itemBeforeReading } == true)
    }

    @Test("a folder lists its children by name, and an image of no folder sits right under the engine")
    func foldersAndUnlistedImages() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let imageItem = try #require(store.item(for: .image(path: TestImages.libobjc)))
        let folderItem = try #require(imageItem.parentItem as? EditorJumpBarItem)

        let names = try #require(Self.childItems(of: folderItem)).map(\.pathComponentName)
        #expect(names == names.sorted())
        #expect(names.contains("libobjc.A.dylib"))
        #expect(store.childItems(of: folderItem) != nil, "a folder's children are there at once")

        let unlistedItem = try #require(store.item(for: .image(path: "/Nowhere/Unlisted.dylib")))
        #expect(unlistedItem.pathComponentName == "Unlisted.dylib")
        #expect(unlistedItem.parentItem === store.rootItems.first)
    }

    // MARK: - Icons

    @Test("the tree's items are drawn in their kinds' colours: a folder, a framework, a dynamic library and an image, listed or not")
    func treeIconColors() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }

        let libobjcItem = try #require(store.item(for: .image(path: TestImages.libobjc)))
        let libFolderItem = try #require(libobjcItem.parentItem as? EditorJumpBarItem)
        // The path the shared cache lists, so that the image is the tree's and not one under the engine.
        let foundationItem = try #require(store.item(for: .image(path: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation")))
        var frameworkItem: EditorJumpBarItem? = foundationItem
        while let item = frameworkItem, item.pathComponentName != "Foundation.framework" {
            frameworkItem = item.parentItem as? EditorJumpBarItem
        }
        let foundationFrameworkItem = try #require(frameworkItem, "Foundation's path has no Foundation.framework")
        let unlistedItem = try #require(store.item(for: .image(path: "/Nowhere/Unlisted.dylib")))
        let unlistedToolItem = try #require(store.item(for: .image(path: "/Nowhere/UnlistedTool")))

        #expect(libFolderItem.pathComponentName == "lib")
        #expect(!(libFolderItem.pathComponentIcon?.isTemplate ?? true), "the path control draws a template image in the text colour")
        #expect(ImageColorSampling.isDrawn(libFolderItem.pathComponentIcon, in: RuntimeImageKind.folder.iconColor))
        #expect(ImageColorSampling.isDrawn(foundationFrameworkItem.pathComponentIcon, in: RuntimeImageKind.framework.iconColor))
        #expect(ImageColorSampling.isDrawn(libobjcItem.pathComponentIcon, in: RuntimeImageKind.dynamicLibrary.iconColor))
        #expect(ImageColorSampling.isDrawn(foundationItem.pathComponentIcon, in: RuntimeImageKind.image.iconColor), "the image inside the framework is an image")
        #expect(ImageColorSampling.isDrawn(unlistedItem.pathComponentIcon, in: RuntimeImageKind.dynamicLibrary.iconColor), "an image under the engine is what its own name says")
        #expect(ImageColorSampling.isDrawn(unlistedToolItem.pathComponentIcon, in: RuntimeImageKind.image.iconColor), "an image under the engine is what its own name says")
    }

    @Test("an image that is not indexed gets its objects once the engine reports it indexed, never before")
    func objectsWaitForTheIndex() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "EditorJumpBarTests.waitsForTheIndex")
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        #expect(try await engine.isImageIndexed(path: TestImages.libobjc) == false)

        let imageItem = try #require(store.item(for: .image(path: TestImages.libobjc)))
        let readEarly = await pollUntil(timeout: .milliseconds(500)) { imageItem.childItems != nil }
        #expect(!readEarly, "the jump bar indexes nothing itself")

        _ = try await engine.objects(in: TestImages.libobjc)

        let didRead = await pollUntil(timeout: .seconds(15)) { imageItem.childItems != nil }
        #expect(didRead)
    }

    @Test("another engine makes the tree again")
    func anotherEngineRebuildsTheTree() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let firstSourceItem = try #require(store.rootItems.first)
        var rebuildCount = 0
        let subscription = store.treeRebuilt.emitOnNext { rebuildCount += 1 }
        defer { subscription.dispose() }
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "EditorJumpBarTests.otherEngine")

        environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine))

        let didRebuild = await pollUntil(timeout: .seconds(15)) {
            store.rootItems.first.map { $0 !== firstSourceItem } ?? false
        }
        #expect(didRebuild)
        #expect(rebuildCount >= 1)
    }

    // MARK: - The adapter

    private func makeAdapter(store: EditorJumpBarItemStore) -> (NSPopUpPathControl, EditorJumpBarAdapter) {
        let pathControl = NSPopUpPathControl(frame: NSRect(x: 0, y: 0, width: 900, height: 22))
        let adapter = EditorJumpBarAdapter(pathControl: pathControl, itemStore: store)
        return (pathControl, adapter)
    }

    private func displayedTitles(of pathControl: NSPopUpPathControl) -> [String] {
        ((pathControl.cell as? NSPopUpPathCell)?.pathComponentCells ?? []).map(\.stringValue)
    }

    @Test("the jump bar shows the path to an object, and an image ends in No Selection")
    func adapterShowsThePath() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let nsObject = try await Self.object(named: "NSObject", in: TestImages.libobjc, of: engine)
        let (pathControl, adapter) = makeAdapter(store: store)
        defer { withExtendedLifetime(adapter) {} }

        adapter.show(.object(nsObject))
        #expect(displayedTitles(of: pathControl).suffix(2) == ["libobjc.A.dylib", "NSObject"])

        adapter.show(.image(path: TestImages.libobjc))
        #expect(displayedTitles(of: pathControl).suffix(2) == ["libobjc.A.dylib", "No Selection"])

        adapter.show(.nothing)
        #expect(displayedTitles(of: pathControl) == ["No Selection"])
    }

    @Test("choosing an image reports it and puts the pane's own path back")
    func choosingAnImage() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let nsObject = try await Self.object(named: "NSObject", in: TestImages.libobjc, of: engine)
        let (pathControl, adapter) = makeAdapter(store: store)
        defer { withExtendedLifetime(adapter) {} }
        adapter.show(.object(nsObject))
        let shownItem = pathControl.selectedItem
        let chosenItem = try #require(store.item(for: .image(path: TestImages.foundation)))
        var choices: [EditorJumpBarChoice] = []
        let subscription = adapter.choiceSelected.emitOnNext { choices.append($0) }
        defer { subscription.dispose() }

        pathControl.selectedItem = chosenItem
        adapter.popUpPathControl(pathControl, didSelect: chosenItem)

        #expect(choices == [EditorJumpBarChoice(target: .image(path: TestImages.foundation), destination: .focusedTab)])
        #expect(pathControl.selectedItem === shownItem)
    }

    @Test("images and objects are chosen, the engine and the folders only lead to them; nested types are inline")
    func whatIsChosen() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let (environment, store) = try await makeStore(on: engine)
        defer { withExtendedLifetime(environment) {} }
        let nsObject = try await Self.object(named: "NSObject", in: TestImages.libobjc, of: engine)
        let (pathControl, adapter) = makeAdapter(store: store)
        defer { withExtendedLifetime(adapter) {} }
        let objectItem = try #require(store.item(for: .object(nsObject)))
        let imageItem = try #require(objectItem.parentItem as? EditorJumpBarItem)
        let folderItem = try #require(imageItem.parentItem as? EditorJumpBarItem)
        let sourceItem = try #require(store.rootItems.first)

        #expect(adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: objectItem))
        #expect(adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: imageItem))
        #expect(!adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: folderItem))
        #expect(!adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: sourceItem))
        #expect(!adapter.popUpPathControl(pathControl, shouldSeparateDisplayOfChildItemsFor: objectItem))
        #expect(adapter.popUpPathControl(pathControl, shouldSeparateDisplayOfChildItemsFor: folderItem))
    }
}

#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
import RuntimeViewerSettings

/// How an engine's recent images and each image's recent objects are recorded
/// (`RecentRuntimeImages`), which an empty editor pane's start page lists (proposal
/// `editor-start-page`).
@Suite("Recent runtime images")
struct RecentRuntimeImagesTests {
    private let recentImages = RecentRuntimeImages(engineKey: "scope:test-engine")

    private let otherImagePath = "/System/Library/Frameworks/Other.framework/Other"

    private func objectNames(in imagesByEngine: [String: [RecentRuntimeImage]], ofImageAt imagePath: String = Fixtures.sampleImagePath) -> [String] {
        recentImages.objects(ofImageAt: imagePath, in: imagesByEngine).map(\.name)
    }

    // MARK: - Objects

    @Test("an object shown puts its image first, with the object first in it")
    func objectShownPutsItsImageFirst() throws {
        let afterImage = try #require(recentImages.recordingImage(at: otherImagePath, in: [:]))
        let afterFirst = try #require(recentImages.recording(Fixtures.runtimeObject(name: "First"), in: afterImage))
        let afterSecond = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Second"), in: afterFirst))

        #expect(recentImages.images(in: afterSecond).map(\.imagePath) == [Fixtures.sampleImagePath, otherImagePath])
        #expect(objectNames(in: afterSecond) == ["Second", "First"])
    }

    @Test("an object shown again moves to the front of its image instead of being listed twice")
    func objectShownAgainMovesToTheFront() throws {
        var imagesByEngine: [String: [RecentRuntimeImage]] = [:]
        for name in ["First", "Second", "Third"] {
            imagesByEngine = try #require(recentImages.recording(Fixtures.runtimeObject(name: name), in: imagesByEngine))
        }

        let updated = try #require(recentImages.recording(Fixtures.runtimeObject(name: "First"), in: imagesByEngine))

        #expect(objectNames(in: updated) == ["First", "Third", "Second"])
        #expect(recentImages.images(in: updated).count == 1)
    }

    @Test("the object first already, in the same form and in the image first already, changes nothing")
    func objectFirstAlreadyChangesNothing() throws {
        let object = Fixtures.runtimeObject(name: "First")
        let imagesByEngine = try #require(recentImages.recording(object, in: [:]))

        #expect(recentImages.recording(object, in: imagesByEngine) == nil)
    }

    @Test("the object first in an image that is not first moves the image to the front")
    func objectFirstInAnImageBehindMovesTheImage() throws {
        let object = Fixtures.runtimeObject(name: "First")
        let afterObject = try #require(recentImages.recording(object, in: [:]))
        let afterOtherImage = try #require(recentImages.recordingImage(at: otherImagePath, in: afterObject))

        let updated = try #require(recentImages.recording(object, in: afterOtherImage))

        #expect(recentImages.images(in: updated).map(\.imagePath) == [Fixtures.sampleImagePath, otherImagePath])
        #expect(objectNames(in: updated) == ["First"])
    }

    @Test("the object first already, in a new form, is kept in the new form")
    func objectFirstAlreadyInNewFormIsReplaced() throws {
        let object = Fixtures.runtimeObject(name: "Sample")
        let exported = Fixtures.runtimeObject(name: "Sample", properties: [.isSwiftClass])
        let imagesByEngine = try #require(recentImages.recording(object, in: [:]))

        let updated = try #require(recentImages.recording(exported, in: imagesByEngine))

        let recorded = recentImages.objects(ofImageAt: Fixtures.sampleImagePath, in: updated)
        #expect(recorded.count == 1)
        #expect(recorded.first?.properties == [.isSwiftClass])
    }

    @Test("an object is kept without its children, so a new child changes nothing")
    func objectIsKeptWithoutItsChildren() throws {
        let generic = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Nested")])
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Nested"), Fixtures.runtimeObject(name: "Generic<Int>")])
        let imagesByEngine = try #require(recentImages.recording(generic, in: [:]))

        #expect(recentImages.objects(ofImageAt: Fixtures.sampleImagePath, in: imagesByEngine).first?.children.isEmpty == true)
        #expect(recentImages.recording(specialized, in: imagesByEngine) == nil)
    }

    @Test("each image keeps at most the maximum count of objects, dropping the oldest")
    func imageKeepsAtMostTheMaximumObjectCount() throws {
        var imagesByEngine: [String: [RecentRuntimeImage]] = [:]
        for index in 0 ..< RecentRuntimeImages.maximumObjectCountPerImage + 3 {
            imagesByEngine = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Object\(index)"), in: imagesByEngine))
        }

        let recorded = objectNames(in: imagesByEngine)
        #expect(RecentRuntimeImages.maximumObjectCountPerImage == 10)
        #expect(recorded.count == RecentRuntimeImages.maximumObjectCountPerImage)
        #expect(recorded.first == "Object\(RecentRuntimeImages.maximumObjectCountPerImage + 2)")
        #expect(recorded.last == "Object3")
    }

    @Test("objects of different images are kept apart")
    func objectsOfDifferentImagesAreKeptApart() throws {
        let afterSample = try #require(recentImages.recording(Fixtures.runtimeObject(name: "InSample"), in: [:]))

        let afterOther = try #require(recentImages.recording(Fixtures.runtimeObject(name: "InOther", imagePath: otherImagePath), in: afterSample))

        #expect(objectNames(in: afterOther) == ["InSample"])
        #expect(objectNames(in: afterOther, ofImageAt: otherImagePath) == ["InOther"])
    }

    // MARK: - Images

    @Test("an image recorded goes first and keeps its objects")
    func imageRecordedGoesFirstAndKeepsItsObjects() throws {
        let afterObject = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Kept"), in: [:]))
        let afterOtherImage = try #require(recentImages.recordingImage(at: otherImagePath, in: afterObject))

        let updated = try #require(recentImages.recordingImage(at: Fixtures.sampleImagePath, in: afterOtherImage))

        #expect(recentImages.images(in: updated).map(\.imagePath) == [Fixtures.sampleImagePath, otherImagePath])
        #expect(objectNames(in: updated) == ["Kept"])
    }

    @Test("the image first already changes nothing")
    func imageFirstAlreadyChangesNothing() throws {
        let imagesByEngine = try #require(recentImages.recordingImage(at: otherImagePath, in: [:]))

        #expect(recentImages.recordingImage(at: otherImagePath, in: imagesByEngine) == nil)
    }

    @Test("the list keeps at most the maximum count of images, and an image dropped takes its objects")
    func listKeepsAtMostTheMaximumImageCount() throws {
        var imagesByEngine = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Oldest"), in: [:]))
        for index in 0 ..< RecentRuntimeImages.maximumImageCount {
            imagesByEngine = try #require(recentImages.recordingImage(at: "/usr/lib/libImage\(index).dylib", in: imagesByEngine))
        }

        let recorded = recentImages.images(in: imagesByEngine).map(\.imagePath)
        #expect(RecentRuntimeImages.maximumImageCount == 10)
        #expect(recorded.count == RecentRuntimeImages.maximumImageCount)
        #expect(recorded.first == "/usr/lib/libImage\(RecentRuntimeImages.maximumImageCount - 1).dylib")
        #expect(!recorded.contains(Fixtures.sampleImagePath))
        #expect(objectNames(in: imagesByEngine).isEmpty)
    }

    @Test("an object or an image without a path records nothing")
    func nothingWithoutAPathIsRecorded() {
        #expect(recentImages.recording(Fixtures.runtimeObject(name: "Pathless", imagePath: ""), in: [:]) == nil)
        #expect(recentImages.recordingImage(at: "", in: [:]) == nil)
    }

    // MARK: - Spelling

    @Test("entries filed under another spelling of an image are folded into it, and no other entry is respelled")
    func entriesUnderAnotherSpellingAreFolded() throws {
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        let imagesByEngine: [String: [RecentRuntimeImage]] = [
            recentImages.engineKey: [
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "Newer", imagePath: rootedSamplePath)]),
                RecentRuntimeImage(imagePath: otherImagePath),
                RecentRuntimeImage(imagePath: rootedSamplePath, objects: [Fixtures.runtimeObject(name: "Older", imagePath: rootedSamplePath)]),
            ],
        ]

        let folded = try #require(recentImages.foldingOtherSpellings(of: rootedSamplePath, in: imagesByEngine) { DyldUtilities.patchImagePathForDyld($0, rootPath: "/sim_root") })

        #expect(recentImages.images(in: folded).map(\.imagePath) == [rootedSamplePath, otherImagePath])
        #expect(recentImages.objects(ofImageAt: rootedSamplePath, in: folded).map(\.name) == ["Newer", "Older"])
    }

    @Test("an object filed under both spellings of an image is listed once after folding")
    func objectUnderBothSpellingsIsListedOnce() throws {
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        let sharedObject = Fixtures.runtimeObject(name: "Shared", imagePath: rootedSamplePath)
        let imagesByEngine: [String: [RecentRuntimeImage]] = [
            recentImages.engineKey: [
                RecentRuntimeImage(imagePath: rootedSamplePath, objects: [sharedObject, Fixtures.runtimeObject(name: "OnlyRooted", imagePath: rootedSamplePath)]),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [sharedObject]),
            ],
        ]

        let folded = try #require(recentImages.foldingOtherSpellings(of: rootedSamplePath, in: imagesByEngine) { DyldUtilities.patchImagePathForDyld($0, rootPath: "/sim_root") })

        #expect(recentImages.objects(ofImageAt: rootedSamplePath, in: folded).map(\.name) == ["Shared", "OnlyRooted"])
    }

    @Test("an entry another root spells as something else is left alone")
    func entryOfAnotherRootIsLeftAlone() throws {
        let firstRootSamplePath = "/first_root" + Fixtures.sampleImagePath
        let imagesByEngine: [String: [RecentRuntimeImage]] = [
            recentImages.engineKey: [RecentRuntimeImage(imagePath: firstRootSamplePath, objects: [Fixtures.runtimeObject(name: "Kept", imagePath: firstRootSamplePath)])],
        ]

        #expect(recentImages.foldingOtherSpellings(of: "/second_root" + Fixtures.sampleImagePath, in: imagesByEngine) { DyldUtilities.patchImagePathForDyld($0, rootPath: "/second_root") } == nil)
    }

    @Test("an image filed under its own spelling only changes nothing")
    func imageUnderItsOwnSpellingChangesNothing() throws {
        let imagesByEngine = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Kept"), in: [:]))

        #expect(recentImages.foldingOtherSpellings(of: Fixtures.sampleImagePath, in: imagesByEngine) { "/sim_root" + $0 } == nil)
    }

    @Test("a folded entry keeps at most the maximum count of objects, the more recent entry's first")
    func foldedEntryKeepsAtMostTheMaximumObjectCount() throws {
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        let imagesByEngine: [String: [RecentRuntimeImage]] = [
            recentImages.engineKey: [
                RecentRuntimeImage(imagePath: rootedSamplePath, objects: (0 ..< 6).map { Fixtures.runtimeObject(name: "Newer\($0)", imagePath: rootedSamplePath) }),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: (0 ..< 6).map { Fixtures.runtimeObject(name: "Older\($0)", imagePath: rootedSamplePath) }),
            ],
        ]

        let folded = try #require(recentImages.foldingOtherSpellings(of: rootedSamplePath, in: imagesByEngine) { DyldUtilities.patchImagePathForDyld($0, rootPath: "/sim_root") })

        let objectNames = recentImages.objects(ofImageAt: rootedSamplePath, in: folded).map(\.name)
        #expect(objectNames == (0 ..< 6).map { "Newer\($0)" } + (0 ..< 4).map { "Older\($0)" })
        #expect(recentImages.images(in: folded).count == 1)
    }

    @Test("each engine keeps a list of its own")
    func eachEngineKeepsItsOwnList() throws {
        let otherEngineImages = RecentRuntimeImages(engineKey: "scope:other-engine")
        let afterFirst = try #require(recentImages.recording(Fixtures.runtimeObject(name: "Mine"), in: [:]))

        let afterOther = try #require(otherEngineImages.recording(Fixtures.runtimeObject(name: "Theirs"), in: afterFirst))

        #expect(objectNames(in: afterOther) == ["Mine"])
        #expect(otherEngineImages.objects(ofImageAt: Fixtures.sampleImagePath, in: afterOther).map(\.name) == ["Theirs"])
    }
}

/// The recorder each window's document session runs: every object the focused pane shows, every
/// image page it shows and every image the sidebar goes into go into the engine's recent images.
@Suite("Recent runtime images recorder", .serialized)
@MainActor
struct RecentRuntimeImagesRecorderTests {
    private func engineKey(of documentState: DocumentState) -> String {
        Settings.Indexing.EngineReference.key(for: documentState.runtimeEngine)
    }

    private func recentObjectNames(in environment: ViewModelTestEnvironment, ofImageAt imagePath: String = Fixtures.sampleImagePath) -> [String]? {
        environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: environment.documentState)]?
            .first { $0.imagePath == imagePath }?
            .objects.map(\.name)
    }

    private func recentImagePaths(in environment: ViewModelTestEnvironment) -> [String]? {
        environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: environment.documentState)]?.map(\.imagePath)
    }

    @Test("an object shown in the focused pane is recorded first in its image")
    func objectShownIsRecorded() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }

        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Second"), in: .focusedTab))

        try await waitUntil { recentObjectNames(in: environment) == ["Second", "First"] }
        #expect(recentImagePaths(in: environment) == [Fixtures.sampleImagePath])
    }

    @Test("the image the sidebar goes into is recorded first")
    func imageTheSidebarGoesIntoIsRecorded() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let otherImagePath = "/usr/lib/libOther.dylib"
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [otherImagePath])
        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Shown"), in: .focusedTab))

        environment.documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: otherImagePath))))

        try await waitUntil { recentImagePaths(in: environment) == [otherImagePath, Fixtures.sampleImagePath] }
        #expect(recentObjectNames(in: environment) == ["Shown"])
    }

    @Test("an image page shown in the focused pane is recorded first")
    func imagePageShownIsRecorded() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let otherImagePath = "/usr/lib/libOther.dylib"
        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Shown"), in: .focusedTab))

        environment.documentState.selectionRouter.trigger(.openImage(otherImagePath, in: .newTab))

        try await waitUntil { recentImagePaths(in: environment) == [otherImagePath, Fixtures.sampleImagePath] }
    }

    @Test("switching back to a tab moves its object to the front")
    func switchingBackToATabMovesItsObjectToTheFront() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let documentState = environment.documentState

        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        let firstTabID = documentState.editorArea.focusedPane.activeTab.id
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Second"), in: .newTab))
        try await waitUntil { recentObjectNames(in: environment) == ["Second", "First"] }

        documentState.selectionRouter.trigger(.switchTab(firstTabID))

        try await waitUntil { recentObjectNames(in: environment) == ["First", "Second"] }
    }

    @Test("an open document session records what its window shows, and a closed one stops")
    func documentSessionRecordsWhileOpen() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RecentRuntimeImagesRecorderTests.session")
        let session = environment.make { DocumentSession(runtimeEngine: engine) }
        let documentState = session.documentState
        let engineKey = engineKey(of: documentState)
        func recentObjectNames() -> [String]? {
            environment.appDefaults.recentRuntimeImagesByEngine[engineKey]?.first?.objects.map(\.name)
        }

        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "BeforeOpening"), in: .focusedTab))
        environment.make { session.open() }
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "WhileOpen"), in: .focusedTab))
        try await waitUntil { recentObjectNames()?.first == "WhileOpen" }

        session.close()
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "AfterClosing"), in: .focusedTab))

        // A record is written from the route itself, and a read waits for every write queued
        // before it: what is not there now was never recorded.
        #expect(recentObjectNames() == ["WhileOpen", "BeforeOpening"])
    }

    @Test("an empty tab records nothing")
    func emptyTabRecordsNothing() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }

        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "First"), in: .focusedTab))
        try await waitUntil { recentObjectNames(in: environment) == ["First"] }

        environment.documentState.selectionRouter.trigger(.newTab)

        #expect(environment.documentState.selectedRuntimeObject == nil)
        #expect(recentObjectNames(in: environment) == ["First"])
        #expect(recentImagePaths(in: environment) == [Fixtures.sampleImagePath])
    }

    @Test("the object on screen shown in a new form does not move to the front")
    func newFormOfTheObjectOnScreenDoesNotMove() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let documentState = environment.documentState
        let generic = Fixtures.runtimeObject(name: "Generic")
        documentState.selectionRouter.trigger(.open(generic, in: .focusedTab))
        environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: documentState)] = [
            RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "SeenElsewhere"), generic]),
        ]

        documentState.selectionRouter.trigger(.selectAtRoot(Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])))

        #expect(documentState.selectedRuntimeObject?.children.count == 1)
        #expect(recentObjectNames(in: environment) == ["SeenElsewhere", "Generic"])
    }

    @Test("on an iOS Simulator engine the image the sidebar goes into and an object of it are filed as one image")
    func simulatorImageAndItsObjectAreOneImage() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = RuntimeEngine(source: .local, engineID: "RecentRuntimeImagesRecorderTests.simulator")
        engine.setDyldRootPathForTesting("/sim_root")
        let documentState = DocumentState(runtimeEngine: engine)
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath])
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath

        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))))
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Shown", imagePath: rootedSamplePath), in: .focusedTab))

        let recentImages = environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: documentState)]
        #expect(recentImages?.map(\.imagePath) == [rootedSamplePath])
        #expect(recentImages?.first?.objects.map(\.name) == ["Shown"])
    }

    @Test("an image filed before the engine learned its peer's spelling is folded into it at the next record")
    func imageFiledBeforeTheSpellingWasKnownIsFolded() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = RuntimeEngine(source: .local, engineID: "RecentRuntimeImagesRecorderTests.lateRoot")
        let documentState = DocumentState(runtimeEngine: engine)
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath])
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))))
        #expect(environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: documentState)]?.map(\.imagePath) == [Fixtures.sampleImagePath])

        engine.setDyldRootPathForTesting("/sim_root")
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Shown", imagePath: rootedSamplePath), in: .focusedTab))

        let recentImages = environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: documentState)]
        #expect(recentImages?.map(\.imagePath) == [rootedSamplePath])
        #expect(recentImages?.first?.objects.map(\.name) == ["Shown"])
    }

    @Test("two engines that share a key, on different roots, leave each other's images as they are")
    func enginesSharingAKeyLeaveEachOthersImages() async throws {
        let environment = ViewModelTestEnvironment()
        let firstEngine = RuntimeEngine(source: .local, engineID: "RecentRuntimeImagesRecorderTests.firstRoot")
        firstEngine.setDyldRootPathForTesting("/first_root")
        let secondEngine = RuntimeEngine(source: .local, engineID: "RecentRuntimeImagesRecorderTests.secondRoot")
        secondEngine.setDyldRootPathForTesting("/second_root")
        let firstDocumentState = DocumentState(runtimeEngine: firstEngine)
        let secondDocumentState = DocumentState(runtimeEngine: secondEngine)
        let recorders = environment.make {
            [RecentRuntimeImagesRecorder(documentState: firstDocumentState), RecentRuntimeImagesRecorder(documentState: secondDocumentState)]
        }
        defer { withExtendedLifetime(recorders) {} }
        let engineKey = Settings.Indexing.EngineReference.key(for: firstEngine)
        #expect(engineKey == Settings.Indexing.EngineReference.key(for: secondEngine))
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath])
        let sampleNode = try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))

        firstDocumentState.selectionRouter.trigger(.switchImage(sampleNode))
        secondDocumentState.selectionRouter.trigger(.switchImage(sampleNode))
        firstDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "OnFirst", imagePath: "/first_root" + Fixtures.sampleImagePath), in: .focusedTab))
        secondDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "OnSecond", imagePath: "/second_root" + Fixtures.sampleImagePath), in: .focusedTab))

        let recentImages = environment.appDefaults.recentRuntimeImagesByEngine[engineKey]
        #expect(recentImages?.map(\.imagePath) == ["/second_root" + Fixtures.sampleImagePath, "/first_root" + Fixtures.sampleImagePath])
        #expect(recentImages?.map { $0.objects.map(\.name) } == [["OnSecond"], ["OnFirst"]])
    }

    @Test("a window moved to another engine files nothing of the engine it left under the new one")
    func windowMovedToAnotherEngineFilesNothingOfTheOldOne() async throws {
        let environment = ViewModelTestEnvironment()
        let recorder = environment.make { RecentRuntimeImagesRecorder(documentState: environment.documentState) }
        defer { withExtendedLifetime(recorder) {} }
        let documentState = environment.documentState
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath])
        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))))
        documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "Shown"), in: .focusedTab))
        try await waitUntil { recentObjectNames(in: environment) == ["Shown"] }
        let otherEngine = TestRuntimeEngine.makeUnreachable()

        documentState.selectionRouter.trigger(.switchEngine(otherEngine))

        #expect(documentState.currentImageNode == nil)
        #expect(environment.appDefaults.recentRuntimeImagesByEngine[Settings.Indexing.EngineReference.key(for: otherEngine)] == nil)
    }

    @Test("two windows on one engine keep one list")
    func twoWindowsOnOneEngineKeepOneList() async throws {
        let environment = ViewModelTestEnvironment()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RecentRuntimeImagesRecorderTests.twoWindows")
        let firstDocumentState = DocumentState(runtimeEngine: engine)
        let secondDocumentState = DocumentState(runtimeEngine: engine)
        let recorders = environment.make {
            [RecentRuntimeImagesRecorder(documentState: firstDocumentState), RecentRuntimeImagesRecorder(documentState: secondDocumentState)]
        }
        defer { withExtendedLifetime(recorders) {} }

        firstDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "InFirstWindow"), in: .focusedTab))
        secondDocumentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(name: "InSecondWindow"), in: .focusedTab))

        let engineKey = Settings.Indexing.EngineReference.key(for: engine)
        #expect(environment.appDefaults.recentRuntimeImagesByEngine[engineKey]?.first?.objects.map(\.name) == ["InSecondWindow", "InFirstWindow"])
    }
}

#endif

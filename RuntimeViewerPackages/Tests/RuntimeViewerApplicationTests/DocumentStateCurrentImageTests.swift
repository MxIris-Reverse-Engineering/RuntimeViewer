import Testing
import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// `isSelectedRuntimeObjectInCurrentImage` decides whether Navigate ▸ Reveal
/// in Sidebar Navigator is enabled: the sidebar only ever lists the rows of
/// `currentImageNode`.
@Suite("DocumentState.isSelectedRuntimeObjectInCurrentImage")
@MainActor
struct DocumentStateCurrentImageTests {
    private static let otherImagePath = "/System/Library/Frameworks/Other.framework/Other"

    /// Both images under one root, the shape the engine publishes. The tree
    /// has to outlive every assertion: a node reaches its root through a weak
    /// `parent`, and derives `path` from it the first time it is asked.
    private let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath, otherImagePath])

    private func sampleImageNode() throws -> RuntimeImageNode {
        try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))
    }

    @Test("an object of the image the sidebar lists is in the current image")
    func objectOfTheListedImage() throws {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.switchImage(try sampleImageNode()))
        documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "SampleClass")))

        #expect(documentState.isSelectedRuntimeObjectInCurrentImage)
    }

    @Test("an object reached in another image is not")
    func objectOfAnotherImage() throws {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.switchImage(try sampleImageNode()))
        documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "OtherClass", imagePath: Self.otherImagePath)))

        #expect(documentState.isSelectedRuntimeObjectInCurrentImage == false)
    }

    @Test("an image with nothing on screen has no object in it")
    func imageWithoutAnObject() throws {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.switchImage(try sampleImageNode()))

        #expect(documentState.isSelectedRuntimeObjectInCurrentImage == false)
    }

    @Test("an empty tab over the image has no object in it")
    func emptyTabOverTheImage() throws {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.switchImage(try sampleImageNode()))
        documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "SampleClass")))
        documentState.selectionRouter.trigger(.newTab)

        #expect(documentState.isSelectedRuntimeObjectInCurrentImage == false)
    }

    @Test("at the image-list root no object is in the current image")
    func imageListRoot() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "SampleClass")))

        #expect(documentState.isSelectedRuntimeObjectInCurrentImage == false)
    }
}

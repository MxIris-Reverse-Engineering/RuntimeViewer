import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences

/// How an engine that borrows shared cache images routes this module's
/// commands: a question about one image goes to the image's owner, a scan of
/// every indexed image is answered by the engine and its owners together, and
/// the prepared-memory questions stay with the engine asked.
@Suite("Cross-reference commands and shared cache owners")
struct CrossReferenceSharedCacheRoutingTests {
    private static let imagePath = "/usr/lib/libobjc.A.dylib"

    private static let object = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: imagePath, children: [])

    private static func spansImages(_ command: some RuntimeEngineCommand) -> Bool {
        command is any RuntimeEngineSpanningCommand || command is any RuntimeEngineSpanningProgressCommand
    }

    @Test("A function's callees are its image's owner's to decode")
    func calleesNameTheFunctionsImage() {
        let command = RuntimeCrossReferences.CalleesCommand(subject: .function(imagePath: Self.imagePath, address: 0x1000), options: .init())

        #expect(command.subjectImagePath == Self.imagePath)
    }

    @Test("A selector names no image")
    func selectorNamesNoImage() {
        let command = RuntimeCrossReferences.CalleesCommand(subject: .selector("init"), options: .init())

        #expect(command.subjectImagePath == nil)
    }

    @Test("A scan of one image goes to that image's owner")
    func scanOfOneImageIsRouted() {
        let callers = RuntimeCrossReferences.CallersCommand(subject: .selector("init"), scope: .image(path: Self.imagePath), options: .init())
        let typeReferences = RuntimeCrossReferences.TypeReferencesCommand(object: Self.object, scope: .image(path: Self.imagePath), options: .init())

        #expect(callers.subjectImagePath == Self.imagePath)
        #expect(typeReferences.subjectImagePath == Self.imagePath)
    }

    @Test("A scan of every indexed image spans the engine and its owners")
    func scanOfEveryImageSpans() {
        let callers = RuntimeCrossReferences.CallersCommand(subject: .selector("init"), scope: .indexedImages, options: .init())
        let typeReferences = RuntimeCrossReferences.TypeReferencesCommand(object: Self.object, scope: .indexedImages, options: .init())

        #expect(callers.subjectImagePath == nil)
        #expect(Self.spansImages(callers))
        #expect(typeReferences.subjectImagePath == nil)
        #expect(Self.spansImages(typeReferences))
    }

    @Test("Preparing an image is its owner's work; the prepared memory is each engine's own")
    func preparationRouting() {
        let prepare = RuntimeCrossReferences.PrepareCommand(imagePath: Self.imagePath, options: .init(residentByteLimit: 0))
        let byteLimit = RuntimeCrossReferences.SetPreparedByteLimitCommand(byteLimit: 0)
        let byteCount = RuntimeCrossReferences.PreparedByteCountCommand()

        #expect(prepare.subjectImagePath == Self.imagePath)
        #expect(byteLimit.subjectImagePath == nil)
        #expect(!Self.spansImages(byteLimit))
        #expect(byteCount.subjectImagePath == nil)
        #expect(!Self.spansImages(byteCount))
    }
}

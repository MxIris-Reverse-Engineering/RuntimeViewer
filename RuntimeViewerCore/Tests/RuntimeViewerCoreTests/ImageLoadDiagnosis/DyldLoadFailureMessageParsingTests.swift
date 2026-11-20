import Testing
@testable import RuntimeViewerCore

/// dyld's message after a refused `dlopen`, read apart. The shapes are dyld's
/// own (dyld-1323), including the two that defeat splitting on commas: a
/// reason holding parentheses and commas, and text after a reason's
/// parenthesis.
@Suite("dyld load failure message parsing")
struct DyldLoadFailureMessageParsingTests {
    @Test("Library not loaded is read with its loader and every path dyld tried")
    func parsesLibraryNotLoadedWithTriedPaths() {
        let message = """
        dlopen(/A/Foo.framework/Foo, 0x0001): Library not loaded: @rpath/Bar.framework/Versions/A/Bar
          Referenced from: <6E1F3A2C-0B7D-3F4E-9A51-2C8D7E4B1F09> /A/Foo.framework/Versions/A/Foo
          Reason: tried: '/usr/lib/swift/Bar.framework/Versions/A/Bar' (no such file, not in dyld cache), '/X/Bar.framework/Versions/A/Bar' (no such file), '/Y/Bar' (blocked by sandbox), not in dyld cache, '/System/Library/Frameworks/Bar.framework/Versions/A/Bar' (no such file, not in dyld cache)
        """

        let parsed = DyldLoadFailureMessage(parsing: message)

        #expect(parsed.requestedImagePath == "/A/Foo.framework/Foo")
        #expect(parsed.failure.kind == .imageNotFound)
        #expect(parsed.failure.missingInstallName == "@rpath/Bar.framework/Versions/A/Bar")
        #expect(parsed.failure.referencingImagePath == "/A/Foo.framework/Versions/A/Foo")
        #expect(parsed.triedPaths.map(\.path) == [
            "/usr/lib/swift/Bar.framework/Versions/A/Bar",
            "/X/Bar.framework/Versions/A/Bar",
            "/Y/Bar",
            "/System/Library/Frameworks/Bar.framework/Versions/A/Bar",
        ])
        #expect(parsed.triedPaths.map(\.reason) == [
            "no such file, not in dyld cache",
            "no such file",
            "blocked by sandbox, not in dyld cache",
            "no such file, not in dyld cache",
        ])
    }

    @Test("Symbol not found is read with the image that wanted it and the image it was expected in")
    func parsesSymbolNotFoundWithExpectedIn() {
        let message = """
        dlopen(/A/Foo.framework/Foo, 0x0001): Symbol not found: _Bar_extra
          Referenced from: <6E1F3A2C-0B7D-3F4E-9A51-2C8D7E4B1F09> /A/Foo.framework/Versions/A/Foo
          Expected in:     <0D9A1C3E-5B2F-3A47-8C61-9E0F2B4D6A18> /A/Foo.framework/Versions/A/Frameworks/Bar.framework/Versions/A/Bar
        """

        let parsed = DyldLoadFailureMessage(parsing: message)

        #expect(parsed.failure.kind == .symbolNotFound)
        #expect(parsed.failure.symbolName == "_Bar_extra")
        #expect(parsed.failure.referencingImagePath == "/A/Foo.framework/Versions/A/Foo")
        #expect(parsed.failure.expectedInImagePath == "/A/Foo.framework/Versions/A/Frameworks/Bar.framework/Versions/A/Bar")
        #expect(parsed.triedPaths.isEmpty)
    }

    @Test("An image without this process's architecture is incompatible, and its reason keeps its parentheses")
    func parsesIncompatibleArchitecture() {
        let message = "dlopen(/A/Qux.dylib, 0x0001): tried: '/A/Qux.dylib' (mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64e or arm64')), '/System/Volumes/Preboot/Cryptexes/OS/A/Qux.dylib' (no such file)"

        let parsed = DyldLoadFailureMessage(parsing: message)

        #expect(parsed.failure.kind == .incompatibleImage)
        #expect(parsed.failure.missingInstallName == "/A/Qux.dylib")
        #expect(parsed.failure.reason == "mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64e or arm64')")
        #expect(parsed.triedPaths.count == 2)
        #expect(parsed.triedPaths.last?.reason == "no such file")
    }

    @Test("A requested image that does not exist is the missing one, with no loader")
    func parsesMissingRequestedImage() {
        let message = "dlopen(/nonexistent/Missing.framework/Versions/A/Missing, 0x0001): tried: '/nonexistent/Missing.framework/Versions/A/Missing' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/nonexistent/Missing.framework/Versions/A/Missing' (no such file)"

        let parsed = DyldLoadFailureMessage(parsing: message)

        #expect(parsed.failure.kind == .imageNotFound)
        #expect(parsed.failure.missingInstallName == "/nonexistent/Missing.framework/Versions/A/Missing")
        #expect(parsed.failure.referencingImagePath == nil)
        #expect(parsed.triedPaths.count == 2)
    }

    @Test("A message of no known shape is unrecognized and keeps its text")
    func unknownMessageIsUnrecognizedAndKeepsTheText() {
        let parsed = DyldLoadFailureMessage(parsing: "dlopen(/A/Foo, 0x0001): something new went wrong")

        #expect(parsed.failure.kind == .unrecognized)
        #expect(parsed.failure.reason == "something new went wrong")
        #expect(parsed.triedPaths.isEmpty)
    }

    @Test("A diagnosis from the message alone names the failed edge and says it is from the message only")
    func messageOnlyDiagnosisReadsTheFailedEdge() {
        let message = """
        dlopen(/A/Foo.framework/Foo, 0x0001): Library not loaded: @rpath/Bar.framework/Versions/A/Bar
          Referenced from: <6E1F3A2C-0B7D-3F4E-9A51-2C8D7E4B1F09> /A/Foo.framework/Versions/A/Foo
          Reason: tried: '/X/Bar.framework/Versions/A/Bar' (no such file)
        """

        let diagnosis = RuntimeImageLoadDiagnosis(dyldMessage: message, imagePath: "/A/Foo.framework/Foo")

        #expect(diagnosis.isFromMessageOnly)
        #expect(diagnosis.dependencyChain == [
            .init(imagePath: "/A/Foo.framework/Versions/A/Foo", installName: "@rpath/Bar.framework/Versions/A/Bar", resolvedPath: nil),
        ])
        #expect(diagnosis.triedPaths.count == 1)
        #expect(diagnosis.remedy == nil)
        #expect(diagnosis.rpathSearches.isEmpty)
    }
}

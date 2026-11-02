import Foundation
import Testing
@testable import RuntimeViewerCore

/// A Swift type this test bundle declares, for the jump below to land on.
struct CrossImageJumpTargetFixture {
    var value: Int
}

/// Jump to Definition on a Swift type whose token was printed in another
/// image: the engine finds the defining section through the Swift factory's
/// table of mangled names. The table used to remember the defining image's own
/// `imagePath` — the install name in its `LC_ID_DYLIB` — instead of the path
/// its section is keyed by, so an image without an install name (this test
/// bundle) or one named `@rpath/…` was never found, and offline a file names
/// itself by its install name too.
@Suite
struct CrossImageSwiftJumpTests {
    /// This test bundle's image, which has no install name.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    @Test("a jump to a Swift type reaches a defining image that has no install name")
    func jumpReachesImageWithoutInstallName() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "CrossImageSwiftJumpTests")
        try await engine.connect()
        let objects = try await engine.objects(in: Self.testBundlePath)
        let target = try #require(objects.first { $0.displayName == "CrossImageJumpTargetFixture" || $0.displayName.hasSuffix(".CrossImageJumpTargetFixture") })
        // The token as it reaches the engine from an interface printed for
        // another image: the mangled name, with that other image's path.
        let token = RuntimeObject(name: target.name, displayName: target.displayName, kind: target.kind, imagePath: "/usr/lib/libobjc.A.dylib", children: [])

        let interface = try await engine.interface(for: token, options: .init())

        #expect(interface?.object.imagePath == Self.testBundlePath)
        #expect(interface?.object.name == target.name)
    }
}

import Testing
import Foundation
import RuntimeViewerCore

/// Regression coverage for the per-image Objective-C protocol listing.
///
/// A previous "protocol ownership" heuristic dropped every protocol whose
/// `protocol_t` was also carried by an image inside the listing image's
/// transitive dependency closure. dyld's `upward` dependencies exist precisely
/// to express cycles, so that closure can contain the image itself —
/// `Foundation ⇄ CoreFoundation`, `UIKitCore ⇄ PrintKitUI/ShareSheet`. Every
/// protocol of such an image is carried by the image itself, so all of them
/// were classified as "imported" and the image listed *no* protocols at all.
///
/// See `Documentations/ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`.
@Suite("ObjC Protocol Listing")
struct ObjCProtocolListingTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    private static func protocolNames(in imagePath: String) async throws -> Set<String> {
        let engine = RuntimeEngine(source: .local, engineID: "test-objc-protocol-listing")
        try await engine.connect()
        try await engine.loadImage(at: imagePath)
        let objects = try await engine.objects(in: imagePath)
        return Set(objects.lazy.filter { $0.kind == .objc(.type(.protocol)) }.map(\.name))
    }

    /// Foundation sits in an `upward` dependency cycle with CoreFoundation, so
    /// it was the archetypal victim: its protocol list came back empty.
    @Test("Image in an upward dependency cycle still lists its ObjC protocols")
    func imageInDependencyCycleListsProtocols() async throws {
        let protocolNames = try await Self.protocolNames(in: Self.foundationPath)

        #expect(!protocolNames.isEmpty, "Foundation listed no Objective-C protocols at all.")
        #expect(protocolNames.contains("NSCoding"))
        #expect(protocolNames.contains("NSCopying"))
        #expect(protocolNames.contains("NSFastEnumeration"))
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// AppKit is *not* in a dependency cycle, so it kept listing protocols even
    /// with the ownership filter in place. It is the control case: the fix must
    /// not regress an image that was already correct.
    @Test("Image outside any dependency cycle keeps listing its ObjC protocols")
    func imageOutsideDependencyCycleListsProtocols() async throws {
        let protocolNames = try await Self.protocolNames(in: "/System/Library/Frameworks/AppKit.framework/AppKit")

        #expect(!protocolNames.isEmpty, "AppKit listed no Objective-C protocols at all.")
        #expect(protocolNames.contains("NSWindowDelegate"))
    }
    #endif
}

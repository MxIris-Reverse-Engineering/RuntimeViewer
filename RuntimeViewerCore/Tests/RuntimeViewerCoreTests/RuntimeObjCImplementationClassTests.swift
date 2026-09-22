import Foundation
import Testing
@testable import RuntimeViewerCore

/// SE-0436's `@objc @implementation` as it reaches the UI. Such a class is a
/// PURE Objective-C class — the Swift bit of its class data pointer is clear —
/// so `isSwiftStable` is false for it and the ObjC metadata alone cannot tell
/// it apart from a clang class. `RuntimeObjCSection` joins in
/// MachOSwiftSection's recognition and records the answer on
/// `RuntimeObject.Properties.isObjCImplementation`, which is what picks the
/// pink badge apart from the blue one a bridged Swift class gets.
///
/// Anchored on macOS 26's AppKit, which rewrote several dozen classes that way.
/// Upstream pins the recognition itself in
/// `ObjCImplementationClassRecognitionTests`; this suite pins only that the fact
/// survives the trip into `RuntimeObject`, through both of the section's
/// factories — `allObjects()` feeds the sidebar, `makeRuntimeObject(forClassName:)`
/// the Inspector's relationship rows, and a badge that appears in one and not
/// the other is the bug this guards.
@Suite(.serialized)
struct RuntimeObjCImplementationClassTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    /// `NSGlassEffectView` is one of the classes macOS 26 rewrote this way.
    private static var runsOnMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// The section reads the image out of *this* process (`MachOImage`), so
    /// AppKit has to be mapped before it can be asked anything — the test
    /// bundle does not link it.
    private func appKitSection() async throws -> RuntimeObjCSection {
        try #require(dlopen(Self.appKitPath, RTLD_LAZY) != nil, "AppKit could not be loaded into the test process")
        let factory = RuntimeObjCSectionFactory()
        return try await factory.section(for: Self.appKitPath).section
    }

    @Test("allObjects marks @objc @implementation classes and leaves clang classes alone", .enabled(if: runsOnMacOS26OrLater, "NSGlassEffectView ships with macOS 26"))
    func allObjectsCarriesTheImplementationFlag() async throws {
        let section = try await appKitSection()
        let objectsByName = Dictionary(
            (try await section.allObjects()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let glassEffectView = try #require(objectsByName["NSGlassEffectView"])
        #expect(glassEffectView.properties.contains(.isObjCImplementation))
        #expect(glassEffectView.kind == .objc(.type(.class)))

        // Clang classes in the same image: the recognition's gate passes for
        // them, no evidence tier does.
        for className in ["NSView", "NSWindow"] {
            let object = try #require(objectsByName[className])
            #expect(!object.properties.contains(.isObjCImplementation), "\(className) should not be marked")
        }
    }

    @Test("makeRuntimeObject agrees with allObjects", .enabled(if: runsOnMacOS26OrLater, "NSGlassEffectView ships with macOS 26"))
    func relationshipRowCarriesTheSameFlag() async throws {
        let section = try await appKitSection()

        let glassEffectView = try #require(await section.makeRuntimeObject(forClassName: "NSGlassEffectView"))
        #expect(glassEffectView.properties.contains(.isObjCImplementation))

        let view = try #require(await section.makeRuntimeObject(forClassName: "NSView"))
        #expect(!view.properties.contains(.isObjCImplementation))
    }

    /// The two badges are mutually exclusive by construction: a bridged Swift
    /// class has the Swift bit set in its class data pointer, an
    /// `@objc @implementation` one has it clear. If that ever stops holding,
    /// `RuntimeObjectIcon.secondaryIcon(for:)` silently starts hiding one of
    /// them behind the other.
    @Test("no class is both bridged-Swift and @objc @implementation", .enabled(if: runsOnMacOS26OrLater, "NSGlassEffectView ships with macOS 26"))
    func theTwoMarkersNeverCoincide() async throws {
        let section = try await appKitSection()
        let objects = try await section.allObjects()

        let marked = objects.filter { $0.properties.contains(.isObjCImplementation) }
        #expect(!marked.isEmpty, "AppKit on macOS 26 implements several dozen classes this way")
        #expect(marked.allSatisfy { $0.secondaryKind == nil })
    }
}

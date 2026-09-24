import AppKit
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The secondary badge: the other face of a class both lists show. On an
/// Objective-C class row two different facts put a `C` there and they say
/// different things — a bridged Swift class (the Swift bit of its class data
/// pointer is set) gets the blue one, a class implemented through SE-0436's
/// `@objc @implementation` (that bit is clear) gets the pink one. The Swift
/// faces answer in kind: a Swift class registered with the Objective-C runtime
/// gets the orange Objective-C `C`, an `@objc @implementation` extension the
/// same pink. `RuntimeObjectIcon.secondaryIcon(for:)` is the single place that
/// chooses, so this pins the choice rather than each call site.
///
/// Identity comparison is exact: `RuntimeObjectIcon` memoizes on
/// (text, color, style, size), so two calls that agree on all four return the
/// same instance and two that differ in colour cannot.
@Suite("RuntimeObjectIcon")
@MainActor
struct RuntimeObjectIconTests {
    @Test("an @objc @implementation class gets the pink badge")
    func objcImplementationGetsPink() {
        let object = Fixtures.runtimeObject(kind: .objc(.type(.class)), properties: [.isObjCImplementation])

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.iconForObjCImplementation())
    }

    @Test("a bridged Swift class keeps the blue badge")
    func bridgedSwiftClassKeepsBlue() {
        let object = Fixtures.runtimeObject(kind: .objc(.type(.class)), properties: [.isSwiftClass])

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.icon(for: .swift(.type(.class))))
    }

    @Test("the two badges are different images")
    func theTwoBadgesDiffer() {
        let objcImplementation = Fixtures.runtimeObject(kind: .objc(.type(.class)), properties: [.isObjCImplementation])
        let bridged = Fixtures.runtimeObject(kind: .objc(.type(.class)), properties: [.isSwiftClass])

        #expect(RuntimeObjectIcon.secondaryIcon(for: objcImplementation) !== RuntimeObjectIcon.secondaryIcon(for: bridged))
    }

    /// The binary cannot produce both at once, but the function still has to
    /// answer if something upstream ever hands it both — silently painting the
    /// blue one over the pink would be the harder bug to spot.
    @Test("the implementation flag wins over the bridged-Swift flag")
    func implementationFlagWins() {
        let object = Fixtures.runtimeObject(
            kind: .objc(.type(.class)),
            properties: [.isObjCImplementation, .isSwiftClass]
        )

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.iconForObjCImplementation())
    }

    @Test("a plain ObjC class gets no badge")
    func plainObjCClassGetsNothing() {
        let object = Fixtures.runtimeObject(kind: .objc(.type(.class)))

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) == nil)
    }

    @Test("a Swift class registered with the ObjC runtime gets the orange ObjC badge")
    func swiftClassWithObjCFaceGetsOrange() {
        let object = Fixtures.runtimeObject(kind: .swift(.type(.class)), properties: [.isObjCClass])

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.icon(for: .objc(.type(.class))))
    }

    @Test("an @objc @implementation extension gets the same pink badge as its class")
    func implementationExtensionGetsPink() {
        let object = Fixtures.runtimeObject(kind: .swift(.extension(.class)), properties: [.isObjCImplementation])

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.iconForObjCImplementation())
    }

    @Test("a plain Swift class gets no badge")
    func plainSwiftClassGetsNothing() {
        let object = Fixtures.runtimeObject(kind: .swift(.type(.class)))

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) == nil)
    }
}

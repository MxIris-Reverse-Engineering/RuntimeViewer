import AppKit
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The secondary badge on an Objective-C class row. Two different facts put a
/// `C` there and they say different things — a bridged Swift class (the Swift
/// bit of its class data pointer is set) gets the blue one, a class implemented
/// through SE-0436's `@objc @implementation` (that bit is clear) gets the pink
/// one. `RuntimeObjectIcon.secondaryIcon(for:)` is the single place that
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
        let object = Fixtures.runtimeObject(kind: .objc(.type(.class)), secondaryKind: .swift(.type(.class)))

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.icon(for: .swift(.type(.class))))
    }

    @Test("the two badges are different images")
    func theTwoBadgesDiffer() {
        let objcImplementation = Fixtures.runtimeObject(kind: .objc(.type(.class)), properties: [.isObjCImplementation])
        let bridged = Fixtures.runtimeObject(kind: .objc(.type(.class)), secondaryKind: .swift(.type(.class)))

        #expect(RuntimeObjectIcon.secondaryIcon(for: objcImplementation) !== RuntimeObjectIcon.secondaryIcon(for: bridged))
    }

    /// The binary cannot produce both at once, but the function still has to
    /// answer if something upstream ever hands it both — silently painting the
    /// blue one over the pink would be the harder bug to spot.
    @Test("the implementation flag wins over a secondary kind")
    func implementationFlagWins() {
        let object = Fixtures.runtimeObject(
            kind: .objc(.type(.class)),
            secondaryKind: .swift(.type(.class)),
            properties: [.isObjCImplementation]
        )

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) === RuntimeObjectIcon.iconForObjCImplementation())
    }

    @Test("a plain ObjC class gets no badge")
    func plainObjCClassGetsNothing() {
        let object = Fixtures.runtimeObject(kind: .objc(.type(.class)))

        #expect(RuntimeObjectIcon.secondaryIcon(for: object) == nil)
    }
}

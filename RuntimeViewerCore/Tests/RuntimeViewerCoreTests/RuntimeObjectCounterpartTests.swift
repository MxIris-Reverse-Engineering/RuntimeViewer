import Foundation
import Testing
@testable import RuntimeViewerCore

/// A class that both the Objective-C and the Swift lists show, and the jump
/// between its two faces (`RuntimeEngine.counterpart(for:)`).
///
/// A bridged class pairs whatever its Objective-C runtime name looks like: a
/// Swift mangling, private discriminator included
/// (`_TtC6AppKitP33_<discriminator>24FontPanelBIUSPopUpButton`), or a name
/// spelled in `@objc(…)` (`NSScrollPocket`). An `@objc @implementation` pair
/// goes through the extension MachOSwiftSection recognized instead.
///
/// Anchored on macOS 26's AppKit, which has both kinds, private and renamed
/// ones included. Every answer is checked against the sidebar's own entry: an
/// object that does not compare equal to it would push without selecting
/// anything.
@Suite(.serialized)
struct RuntimeObjectCounterpartTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static var runsOnMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// One engine with AppKit loaded and indexed for the whole suite —
    /// indexing AppKit takes a while — plus the objects it lists.
    private static let sharedAppKit = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeObjectCounterpartTests")
        try await engine.connect()
        try await engine.loadImage(at: appKitPath)
        return (engine, try await engine.objects(in: appKitPath))
    }

    @Test("a private bridged class and its Swift class jump to each other", .enabled(if: runsOnMacOS26OrLater, "the anchor classes ship with macOS 26's AppKit"))
    func privateBridgedClassJumpsBothWays() async throws {
        try await Self.expectBridgedClassJumpsBothWays { $0.hasPrefix("_TtC6AppKitP33_") && $0.hasSuffix("24FontPanelBIUSPopUpButton") }
    }

    /// Private and nested in a type: the discriminator sits on the nested name
    /// (`AppKit.NSScrollPocket.(ElementContainerModel in _…)`).
    @Test("a private nested bridged class and its Swift class jump to each other", .enabled(if: runsOnMacOS26OrLater, "the anchor classes ship with macOS 26's AppKit"))
    func privateNestedBridgedClassJumpsBothWays() async throws {
        try await Self.expectBridgedClassJumpsBothWays { $0.hasPrefix("_TtCC6AppKit14NSScrollPocketP33_") && $0.hasSuffix("21ElementContainerModel") }
    }

    /// Declared `@objc(NSScrollPocket)`: the runtime name is the one the source
    /// spelled, not a Swift mangling, and says nothing about the module or the
    /// type it belongs to.
    @Test("a class renamed with @objc(…) and its Swift class jump to each other", .enabled(if: runsOnMacOS26OrLater, "the anchor classes ship with macOS 26's AppKit"))
    func renamedBridgedClassJumpsBothWays() async throws {
        let swiftObject = try await Self.expectBridgedClassJumpsBothWays { $0 == "NSScrollPocket" }
        #expect(swiftObject.displayName == "AppKit.NSScrollPocket")
    }

    @Test("an @objc @implementation class and its extension jump to each other", .enabled(if: runsOnMacOS26OrLater, "NSGlassEffectView ships with macOS 26"))
    func implementationClassAndItsExtensionJumpToEachOther() async throws {
        let (engine, objects) = try await Self.sharedAppKit.value
        let objcObject = try #require(objects.first { $0.kind == .objc(.type(.class)) && $0.name == "NSGlassEffectView" })
        #expect(objcObject.counterpartKind == .swiftImplementation)

        let extensionObject = try #require(try await engine.counterpart(for: objcObject))
        #expect(extensionObject.kind == .swift(.extension(.class)))
        #expect(extensionObject.properties.contains(.isObjCImplementation))
        let sidebarEntry = try #require(Self.flattened(objects).first { $0 == extensionObject }, "the extension must be the sidebar's own entry")
        #expect(sidebarEntry.properties.contains(.isObjCImplementation))
        #expect(sidebarEntry.counterpartKind == .objcClass)

        #expect(try await engine.counterpart(for: extensionObject) == objcObject)
    }

    /// Every bridged class — whether its runtime name is a Swift mangling or
    /// one spelled in `@objc(…)` — finds its Swift face and comes back to
    /// itself, and every Swift class marked as registered with the Objective-C
    /// runtime finds its Objective-C face — the two marks describe the same set
    /// of classes.
    @Test("every bridged class and every marked Swift class round-trips", .enabled(if: runsOnMacOS26OrLater, "the anchor classes ship with macOS 26's AppKit"))
    func everyPairRoundTrips() async throws {
        let (engine, objects) = try await Self.sharedAppKit.value
        let bridgedObjCClasses = objects.filter {
            $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass)
        }
        var failures: [String] = []
        for objcObject in bridgedObjCClasses {
            guard let swiftObject = try await engine.counterpart(for: objcObject) else {
                failures.append("\(objcObject.name): no Swift face")
                continue
            }
            if !swiftObject.properties.contains(.isObjCClass) {
                failures.append("\(objcObject.name): Swift face \(swiftObject.displayName) is not marked isObjCClass")
            }
            if try await engine.counterpart(for: swiftObject) != objcObject {
                failures.append("\(objcObject.name): Swift face \(swiftObject.displayName) does not lead back")
            }
        }
        let markedSwiftClasses = Self.flattened(objects).filter {
            $0.kind == .swift(.type(.class)) && $0.properties.contains(.isObjCClass)
        }
        for swiftObject in markedSwiftClasses {
            if try await engine.counterpart(for: swiftObject) == nil {
                failures.append("\(swiftObject.displayName): marked isObjCClass but no Objective-C face")
            }
        }
        #expect(bridgedObjCClasses.count > 100, "AppKit on macOS 26 registers well over a hundred Swift classes")
        #expect(markedSwiftClasses.count == bridgedObjCClasses.count)
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.joined(separator: "\n"))")
    }

    @Test("objects without another face answer nil", .enabled(if: runsOnMacOS26OrLater, "the anchor classes ship with macOS 26's AppKit"))
    func objectsWithoutAnotherFaceAnswerNil() async throws {
        let (engine, objects) = try await Self.sharedAppKit.value
        let clangClass = try #require(objects.first { $0.kind == .objc(.type(.class)) && $0.name == "NSView" })
        let swiftStructure = try #require(objects.first { $0.kind == .swift(.type(.struct)) })

        for object in [clangClass, swiftStructure] {
            #expect(object.counterpartKind == nil, "\(object.displayName) should offer no jump")
            #expect(try await engine.counterpart(for: object) == nil)
        }
    }

    /// `counterpartKind` reads only the kind and the marks, so a menu can be
    /// titled without asking the engine.
    @Test("counterpartKind follows the kind and the marks")
    func counterpartKindFollowsKindAndMarks() {
        func object(_ kind: RuntimeObjectKind, _ properties: RuntimeObject.Properties) -> RuntimeObject {
            RuntimeObject(name: "Name", displayName: "Name", kind: kind, imagePath: "/Image", children: [], properties: properties)
        }
        #expect(object(.objc(.type(.class)), [.isSwiftClass]).counterpartKind == .swiftClass)
        #expect(object(.objc(.type(.class)), [.isObjCImplementation]).counterpartKind == .swiftImplementation)
        #expect(object(.objc(.type(.class)), []).counterpartKind == nil)
        #expect(object(.swift(.type(.class)), [.isObjCClass]).counterpartKind == .objcClass)
        #expect(object(.swift(.type(.class)), []).counterpartKind == nil)
        #expect(object(.swift(.extension(.class)), [.isObjCImplementation]).counterpartKind == .objcClass)
        #expect(object(.swift(.extension(.class)), []).counterpartKind == nil)
        #expect(object(.swift(.type(.struct)), [.isObjCClass]).counterpartKind == nil)
    }

    // MARK: - Helpers

    /// Returns the Swift face, for a caller that wants to check which type it is.
    @discardableResult
    private static func expectBridgedClassJumpsBothWays(whereRuntimeName isAnchor: (String) -> Bool) async throws -> RuntimeObject {
        let (engine, objects) = try await sharedAppKit.value
        let objcObject = try #require(objects.first {
            $0.kind == .objc(.type(.class)) && isAnchor($0.name)
        })
        #expect(objcObject.counterpartKind == .swiftClass)

        let swiftObject = try #require(try await engine.counterpart(for: objcObject), "\(objcObject.name) found no Swift face")
        #expect(swiftObject.kind == .swift(.type(.class)))
        #expect(swiftObject.properties.contains(.isObjCClass))
        let sidebarEntry = try #require(flattened(objects).first { $0 == swiftObject }, "the Swift face must be the sidebar's own entry")
        #expect(sidebarEntry.properties.contains(.isObjCClass))

        #expect(try await engine.counterpart(for: swiftObject) == objcObject)
        return swiftObject
    }

    /// The listed objects with every nested child, the way the sidebar's
    /// outline shows them.
    private static func flattened(_ objects: [RuntimeObject]) -> [RuntimeObject] {
        objects.flatMap { [$0] + flattened($0.children) }
    }
}

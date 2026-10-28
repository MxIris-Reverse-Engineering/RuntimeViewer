import Foundation
import Testing
@testable import RuntimeViewerCore

/// Renamed with `@objc(…)`, so its runtime name reads like any clang
/// protocol's and only the Swift bit of its record says where it was written.
@objc(RuntimeViewerCoreTestsRenamedSwiftProtocol)
protocol RenamedSwiftObjCProtocolFixture {
    func renamedRequirement()
}

/// Listed under the runtime name Swift gives it, `_TtP<module><name>_`.
@objc
protocol MangledSwiftObjCProtocolFixture {
    func mangledRequirement()
}

/// `RuntimeObject.Properties.isSwiftProtocol`: which Objective-C protocols an
/// image lists were defined in Swift (`SwiftDefinedObjCProtocols`).
///
/// The rule is pinned on records written out by hand, because the two cases it
/// exists for — the copy clang emits for a Swift protocol, and an image holding
/// two records of one protocol — have no anchor that every system carries. That
/// the mark reaches `RuntimeObject` is pinned on the two protocols this test
/// bundle declares above, through both of the section's factories:
/// `allObjects()` feeds the sidebar, `makeRuntimeObject(forProtocolName:)` the
/// Inspector's relationship rows.
@Suite
struct SwiftDefinedObjCProtocolTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    /// The runtime names the two fixtures are listed under, written out:
    /// `NSStringFromProtocol` hands back the name the Objective-C runtime
    /// demangles a `_TtP…_` name to, not the name the record carries.
    private static let fixtureNames = [
        "RuntimeViewerCoreTestsRenamedSwiftProtocol",
        "_TtP22RuntimeViewerCoreTests31MangledSwiftObjCProtocolFixture_",
    ]

    // MARK: - The rule

    @Test("a record carrying the Swift bit is Swift-defined, whatever its name")
    func swiftBitMarksARenamedProtocol() {
        let names = SwiftDefinedObjCProtocols.names(of: [(name: "RenamedProtocol", flags: 0x1)])
        #expect(names == ["RenamedProtocol"])
    }

    @Test("the Swift bit still counts once the runtime has set its own bits")
    func swiftBitCountsBesideTheRuntimeBits() {
        // 0x6000_0000 is what the shared cache builder sets on the canonical
        // copy of every protocol: fixed up, and canonical.
        let names = SwiftDefinedObjCProtocols.names(of: [(name: "RenamedProtocol", flags: 0x6000_0001)])
        #expect(names == ["RenamedProtocol"])
    }

    @Test("the copy clang emits for a Swift protocol is recognized by its mangled name")
    func mangledNameMarksTheClangCopy() {
        // The record DVTFoundation holds for DVTNFASupport's protocol: clang
        // wrote it, so its flags are zero.
        let names = SwiftDefinedObjCProtocols.names(of: [(name: "_TtP13DVTNFASupport24NFAImageDownloadObserver_", flags: 0)])
        #expect(names == ["_TtP13DVTNFASupport24NFAImageDownloadObserver_"])
    }

    @Test("a protocol written in Objective-C is not marked, whatever bits the runtime set", arguments: [UInt32(0), 0x6000_0000, 0x8000_0000])
    func clangProtocolIsNotMarked(flags: UInt32) {
        #expect(SwiftDefinedObjCProtocols.names(of: [(name: "NSCopying", flags: flags)]).isEmpty)
    }

    @Test("one qualifying record of a name marks it, whichever comes last", arguments: [
        [(name: "RenamedProtocol", flags: UInt32(0x1)), (name: "RenamedProtocol", flags: UInt32(0))],
        [(name: "RenamedProtocol", flags: UInt32(0)), (name: "RenamedProtocol", flags: UInt32(0x1))],
    ])
    func anyRecordOfANameMarksIt(records: [(name: String, flags: UInt32)]) {
        #expect(SwiftDefinedObjCProtocols.names(of: records) == ["RenamedProtocol"])
    }

    // MARK: - Reaching RuntimeObject

    /// The section of this test bundle, where the two fixtures are declared.
    private func testBundleSection() async throws -> RuntimeObjCSection {
        var information = Dl_info()
        try #require(dladdr(#dsohandle, &information) != 0)
        let path = String(cString: try #require(information.dli_fname))
        return try await RuntimeObjCSectionFactory().section(for: path).section
    }

    @Test("the fixtures reach the runtime under the names the suite looks them up by")
    func fixturesKeepTheirNames() {
        // The renamed one carries no trace of Swift, so only the bit can mark it.
        #expect(NSStringFromProtocol(RenamedSwiftObjCProtocolFixture.self) == Self.fixtureNames[0])
        // The runtime demangles the other one's record name for display.
        #expect(NSStringFromProtocol(MangledSwiftObjCProtocolFixture.self) == "RuntimeViewerCoreTests.MangledSwiftObjCProtocolFixture")
    }

    @Test("allObjects marks the protocols this bundle declares in Swift")
    func allObjectsMarksSwiftProtocols() async throws {
        let section = try await testBundleSection()
        let objectsByName = Dictionary(
            (try await section.allObjects()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for name in Self.fixtureNames {
            let object = try #require(objectsByName[name], "\(name) is not listed")
            #expect(object.kind == .objc(.type(.protocol)))
            #expect(object.properties.contains(.isSwiftProtocol), "\(name) should be marked")
        }
    }

    @Test("makeRuntimeObject agrees with allObjects")
    func relationshipRowCarriesTheSameMark() async throws {
        let section = try await testBundleSection()

        for name in Self.fixtureNames {
            let object = try #require(await section.makeRuntimeObject(forProtocolName: name))
            #expect(object.properties.contains(.isSwiftProtocol), "\(name) should be marked")
        }
    }

    @Test("a protocol written in Objective-C stays unmarked in a real image")
    func objectiveCProtocolStaysUnmarked() async throws {
        let section = try await RuntimeObjCSectionFactory().section(for: Self.foundationPath).section

        let copying = try #require(await section.makeRuntimeObject(forProtocolName: "NSCopying"))
        #expect(!copying.properties.contains(.isSwiftProtocol))
    }
}

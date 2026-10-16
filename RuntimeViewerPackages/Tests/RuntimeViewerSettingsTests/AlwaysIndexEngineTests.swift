import Foundation
import Testing
import RuntimeViewerCommunication
import RuntimeViewerCore

@testable import RuntimeViewerSettings

/// Which engines an Always Index row applies to, and what it matches an engine by.
///
/// The keys are persisted in the settings file, so their spelling is pinned here: a change to it
/// would silently drop every engine choice a user has made.
@Suite("Always Index engines")
struct AlwaysIndexEngineTests {
    struct EngineKeyCase: Sendable, CustomTestStringConvertible {
        let label: String
        let source: RuntimeSource
        let bookmarkScope: RuntimeBookmarkScope?
        let expectedKey: String

        var testDescription: String { label }
    }

    static let engineKeyCases: [EngineKeyCase] = [
        EngineKeyCase(
            label: "My Mac",
            source: .local,
            bookmarkScope: nil,
            expectedKey: "scope:v1:local::"
        ),
        EngineKeyCase(
            label: "Mac Catalyst",
            source: .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client),
            bookmarkScope: nil,
            expectedKey: "scope:v1:remote:client:com.RuntimeViewer.RuntimeSource.MacCatalyst"
        ),
        EngineKeyCase(
            label: "process attached over XPC",
            source: .remote(name: "Safari", identifier: "4242", role: .client),
            bookmarkScope: nil,
            expectedKey: "process:Safari"
        ),
        EngineKeyCase(
            label: "process attached over a local socket",
            source: .localSocket(name: "Notes", identifier: "4343", role: .client),
            bookmarkScope: nil,
            expectedKey: "process:Notes"
        ),
        EngineKeyCase(
            label: "process on a device",
            source: .bonjour(name: "SpringBoard", identifier: "DEVICE-1-77", role: .client),
            bookmarkScope: .identified(.bonjour(deviceID: "DEVICE-1", processName: "SpringBoard", role: .client)),
            expectedKey: "scope:v1:bonjour:client:DEVICE-1:SpringBoard"
        ),
        EngineKeyCase(
            label: "direct TCP peer",
            source: .directTCP(name: "Lab Mac", host: "192.168.1.2", port: 9000, role: .client),
            bookmarkScope: nil,
            expectedKey: "scope:v1:directTCP:client:9000:192.168.1.2"
        ),
        EngineKeyCase(
            label: "Bonjour peer with no device identity",
            source: .bonjour(name: "Old Peer", identifier: "Old Peer", role: .client),
            bookmarkScope: nil,
            expectedKey: "scope:bonjour.Old Peer"
        ),
    ]

    @Test("each kind of engine is matched by the key its identity gives it", arguments: engineKeyCases)
    func engineKey(of engineKeyCase: EngineKeyCase) {
        let engine = RuntimeEngine(source: engineKeyCase.source, bookmarkScope: engineKeyCase.bookmarkScope)
        #expect(Settings.Indexing.EngineReference.key(for: engine) == engineKeyCase.expectedKey)
    }

    @Test("an attached process keeps its key when it relaunches under a new process identifier")
    func attachedProcessKeySurvivesRelaunch() {
        let firstLaunch = RuntimeEngine(source: .remote(name: "Safari", identifier: "4242", role: .client))
        let secondLaunch = RuntimeEngine(source: .remote(name: "Safari", identifier: "5151", role: .client))
        #expect(Settings.Indexing.EngineReference.key(for: firstLaunch) == Settings.Indexing.EngineReference.key(for: secondLaunch))
    }

    @Test("same-named processes on two devices are two engines")
    func sameNamedDeviceProcessesDiffer() {
        let firstDevice = RuntimeEngine(
            source: .bonjour(name: "SpringBoard", identifier: "DEVICE-1-77", role: .client),
            bookmarkScope: .identified(.bonjour(deviceID: "DEVICE-1", processName: "SpringBoard", role: .client))
        )
        let secondDevice = RuntimeEngine(
            source: .bonjour(name: "SpringBoard", identifier: "DEVICE-2-77", role: .client),
            bookmarkScope: .identified(.bonjour(deviceID: "DEVICE-2", processName: "SpringBoard", role: .client))
        )
        #expect(Settings.Indexing.EngineReference.key(for: firstDevice) != Settings.Indexing.EngineReference.key(for: secondDevice))
    }

    @Test("a reference to an engine carries its key and the names it is shown under")
    func referenceToEngine() {
        let engine = RuntimeEngine(
            source: .remote(name: "Safari", identifier: "4242", role: .client),
            hostInfo: RuntimeHostInfo(hostID: "host-1", hostName: "Studio")
        )
        let reference = Settings.Indexing.EngineReference(engine: engine)
        #expect(reference == Settings.Indexing.EngineReference(key: "process:Safari", name: "Safari", hostName: "Studio"))
    }

    @Test("a row persisted before engines could be chosen applies to every engine")
    func legacyRowAppliesToEveryEngine() throws {
        let persistedRow = Data(#"{"isEnabled":true,"identifier":"SwiftUI","followDependencies":false}"#.utf8)
        let entry = try JSONDecoder().decode(Settings.Indexing.AlwaysIndexEntry.self, from: persistedRow)
        #expect(entry.appliesToAllEngines)
        #expect(entry.engines.isEmpty)
        #expect(entry.applies(toEngineWithKey: "scope:v1:local::"))
        #expect(entry.applies(toEngineWithKey: "process:Safari"))
    }

    @Test("a row limited to engines keeps them through a save and a load")
    func limitedRowRoundTrips() throws {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        entry.setEngine(Self.myMac, isSelected: true)
        entry.setEngine(Self.safari, isSelected: true)

        let decoded = try JSONDecoder().decode(Settings.Indexing.AlwaysIndexEntry.self, from: JSONEncoder().encode(entry))

        #expect(decoded == entry)
        #expect(!decoded.appliesToAllEngines)
        #expect(decoded.engines == [Self.myMac, Self.safari])
    }

    @Test("a row limited to engines applies to those engines only")
    func limitedRowAppliesToItsEnginesOnly() {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        entry.setEngine(Self.safari, isSelected: true)
        #expect(entry.applies(toEngineWithKey: "process:Safari"))
        #expect(!entry.applies(toEngineWithKey: "scope:v1:local::"))
    }

    @Test("selecting an engine on a row for every engine limits it to that engine alone")
    func selectingFromAllEnginesNarrows() {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        #expect(!entry.selectsEngine(withKey: "process:Safari"))

        entry.setEngine(Self.safari, isSelected: true)

        #expect(!entry.appliesToAllEngines)
        #expect(entry.engines == [Self.safari])
        #expect(entry.selectsEngine(withKey: "process:Safari"))
    }

    @Test("deselecting the last engine leaves the row on no engine")
    func deselectingLastEngineAppliesNowhere() {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        entry.setEngine(Self.safari, isSelected: true)

        entry.setEngine(Self.safari, isSelected: false)

        #expect(!entry.appliesToAllEngines)
        #expect(entry.engines.isEmpty)
        #expect(!entry.applies(toEngineWithKey: "process:Safari"))
        #expect(!entry.applies(toEngineWithKey: "scope:v1:local::"))
    }

    @Test("switching a row to every engine and back restores the engines it was limited to")
    func allEnginesRoundTripRestoresSelection() {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        entry.setEngine(Self.myMac, isSelected: true)
        entry.setEngine(Self.safari, isSelected: true)

        entry.appliesToAllEngines = true
        #expect(!entry.selectsEngine(withKey: "process:Safari"))
        entry.appliesToAllEngines = false

        #expect(entry.engines == [Self.myMac, Self.safari])
    }

    @Test("selecting an engine twice lists it once")
    func selectingTwiceListsOnce() {
        var entry = Settings.Indexing.AlwaysIndexEntry(identifier: "SwiftUI")
        entry.setEngine(Self.myMac, isSelected: true)
        entry.setEngine(Self.safari, isSelected: true)
        entry.setEngine(Self.safari, isSelected: true)
        #expect(entry.engines == [Self.myMac, Self.safari])
    }

    private static let myMac = Settings.Indexing.EngineReference(key: "scope:v1:local::", name: "My Mac", hostName: "Studio")

    private static let safari = Settings.Indexing.EngineReference(key: "process:Safari", name: "Safari", hostName: "Studio")
}

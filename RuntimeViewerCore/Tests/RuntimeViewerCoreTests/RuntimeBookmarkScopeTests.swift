import Testing
import Foundation
@testable import RuntimeViewerCore
import RuntimeViewerCommunication

// MARK: - String representation

@Suite("RuntimeBookmarkScope.Identity string representation")
struct RuntimeBookmarkScopeIdentityRawValueTests {
    @Test("Every kind round-trips through its raw value")
    func roundTripsEveryKind() throws {
        let identities: [RuntimeBookmarkScope.Identity] = [
            .local,
            .remote(identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .client),
            .remote(identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .server),
            .localSocket(identifier: "1234", role: .client),
            .directTCP(port: 8080, host: "192.168.1.10", role: .client),
            .directTCP(port: 0, host: nil, role: .server),
            .bonjour(deviceID: "11111111-2222-3333-4444-555555555555", processName: "SpringBoard", role: .client),
        ]

        for identity in identities {
            let decoded = RuntimeBookmarkScope.Identity(rawValue: identity.rawValue)
            #expect(decoded == identity, "\(identity.rawValue) did not round-trip")
        }
    }

    @Test("Raw values are the documented, readable shape")
    func rawValueShape() {
        #expect(RuntimeBookmarkScope.Identity.local.rawValue == "v1:local::")
        #expect(
            RuntimeBookmarkScope.Identity
                .remote(identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .client)
                .rawValue == "v1:remote:client:com.RuntimeViewer.RuntimeSource.MacCatalyst"
        )
        #expect(
            RuntimeBookmarkScope.Identity
                .bonjour(deviceID: "DEVICE", processName: "SpringBoard", role: .client)
                .rawValue == "v1:bonjour:client:DEVICE:SpringBoard"
        )
        // Port leads so that a colon-bearing IPv6 host can swallow the tail.
        #expect(
            RuntimeBookmarkScope.Identity
                .directTCP(port: 8080, host: "fe80::1", role: .client)
                .rawValue == "v1:directTCP:client:8080:fe80::1"
        )
    }

    @Test(
        "A process name survives whatever it contains",
        arguments: [
            "SpringBoard",
            "Time: The App",
            "a:b:c:d",
            "名前のあるプロセス",
            "Emoji 🚀 Runner",
            "  leading and trailing  ",
            "",
        ]
    )
    func processNameSurvivesArbitraryContent(processName: String) throws {
        let identity = RuntimeBookmarkScope.Identity.bonjour(
            deviceID: "11111111-2222-3333-4444-555555555555",
            processName: processName,
            role: .client
        )
        let decoded = try #require(RuntimeBookmarkScope.Identity(rawValue: identity.rawValue))
        #expect(decoded == identity)
        guard case .bonjour(_, let decodedProcessName, _) = decoded else {
            Issue.record("expected a bonjour identity")
            return
        }
        #expect(decodedProcessName == processName)
    }

    @Test(
        "An IPv6 host survives its own colons",
        arguments: [
            "fe80::1",
            "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            "::1",
            "192.168.1.10",
        ]
    )
    func ipv6HostSurvivesItsOwnColons(host: String) throws {
        let identity = RuntimeBookmarkScope.Identity.directTCP(port: 9000, host: host, role: .client)
        let decoded = try #require(RuntimeBookmarkScope.Identity(rawValue: identity.rawValue))
        #expect(decoded == identity)
    }

    @Test(
        "Malformed raw values are rejected rather than half-parsed",
        arguments: [
            "",
            "v1",
            "v1:bonjour:client",                       // remainder segment missing
            "v2:bonjour:client:DEVICE:Process",        // future format version
            "v1:carrierPigeon:client:whatever",        // unknown kind
            "v1:bonjour:overlord:DEVICE:Process",      // unknown role
            "v1:bonjour:client::Process",              // empty device ID
            "v1:local:client:",                        // local carries no role
            "v1:local::something",                     // local carries no remainder
            "v1:remote:client:",                       // empty identifier
            "v1:directTCP:client:notaport:host",       // non-numeric port
            "v1:directTCP:client:99999:host",          // port out of UInt16 range
            "bonjour.11111111-2222-3333-4444-555555555555-4242",  // a legacy key
        ]
    )
    func rejectsMalformedRawValues(rawValue: String) {
        #expect(RuntimeBookmarkScope.Identity(rawValue: rawValue) == nil, "\(rawValue) should not parse")
    }

    @Test("The device ID segment can be lifted out without decoding the rest")
    func deviceIdentifierIsReachableForFutureMigration() {
        let identity = RuntimeBookmarkScope.Identity.bonjour(
            deviceID: "11111111-2222-3333-4444-555555555555",
            processName: "Weird:Name",
            role: .client
        )
        #expect(
            RuntimeBookmarkScope.Identity.deviceIdentifier(inRawValue: identity.rawValue)
                == "11111111-2222-3333-4444-555555555555"
        )
        // Every other kind, and a legacy key, must answer nil rather than
        // handing back some other segment.
        #expect(RuntimeBookmarkScope.Identity.deviceIdentifier(inRawValue: "v1:local::") == nil)
        #expect(RuntimeBookmarkScope.Identity.deviceIdentifier(inRawValue: "v1:directTCP:client:80:host") == nil)
        #expect(RuntimeBookmarkScope.Identity.deviceIdentifier(inRawValue: "bonjour.DEVICE-4242") == nil)
    }
}

// MARK: - Recovery from a RuntimeSource

@Suite("RuntimeBookmarkScope.recovered(from:)")
struct RuntimeBookmarkScopeRecoveryTests {
    @Test("Non-Bonjour sources map across one-to-one")
    func nonBonjourSourcesMapOneToOne() {
        #expect(RuntimeBookmarkScope.recovered(from: .local) == .identified(.local))
        #expect(
            RuntimeBookmarkScope.recovered(
                from: .remote(name: "My Mac (Mac Catalyst)", identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .client)
            ) == .identified(.remote(identifier: "com.RuntimeViewer.RuntimeSource.MacCatalyst", role: .client))
        )
        #expect(
            RuntimeBookmarkScope.recovered(
                from: .localSocket(name: "Sandboxed App", identifier: "4242", role: .client)
            ) == .identified(.localSocket(identifier: "4242", role: .client))
        )
        #expect(
            RuntimeBookmarkScope.recovered(
                from: .directTCP(name: "Peer", host: "fe80::1", port: 8080, role: .client)
            ) == .identified(.directTCP(port: 8080, host: "fe80::1", role: .client))
        )
    }

    @Test("The display name never reaches a recovered non-Bonjour scope")
    func displayNameIsNotPartOfIdentity() {
        let first = RuntimeSource.remote(name: "One Name", identifier: "shared-identifier", role: .client)
        let second = RuntimeSource.remote(name: "A Completely Different Name", identifier: "shared-identifier", role: .client)
        #expect(RuntimeBookmarkScope.recovered(from: first) == RuntimeBookmarkScope.recovered(from: second))
    }

    @Test("A pid-bearing Bonjour identifier gives up its device half")
    func bonjourClientIdentifierYieldsDeviceIdentifier() {
        let source = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-4242",
            role: .client
        )
        #expect(
            RuntimeBookmarkScope.recovered(from: source)
                == .identified(.bonjour(
                    deviceID: "11111111-2222-3333-4444-555555555555",
                    processName: "SpringBoard",
                    role: .client
                ))
        )
    }

    @Test("The recovered scope drops the process identifier, so a relaunch keeps its scope")
    func relaunchKeepsItsScope() {
        let firstLaunch = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-4242",
            role: .client
        )
        let secondLaunch = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-9999",
            role: .client
        )
        // The sources themselves are *not* equal — that inequality is exactly
        // what used to lose the bookmarks.
        #expect(firstLaunch != secondLaunch)
        #expect(RuntimeBookmarkScope.recovered(from: firstLaunch) == RuntimeBookmarkScope.recovered(from: secondLaunch))
    }

    @Test("Two devices running the same process stay apart")
    func sameProcessOnTwoDevicesStaysApart() {
        let firstDevice = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-4242",
            role: .client
        )
        let secondDevice = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "99999999-8888-7777-6666-555555555555-4242",
            role: .client
        )
        #expect(RuntimeBookmarkScope.recovered(from: firstDevice) != RuntimeBookmarkScope.recovered(from: secondDevice))
    }

    @Test(
        "An identifier that is not a device key is refused, never guessed at",
        arguments: [
            "JHs-iPhone (RuntimeViewer)",     // the pre-simulator-injection service name
            "11111111-2222-3333-4444-555555555555",  // a UUID whose final group is all digits
            "11111111-2222-3333-4444-000000004242",  // ditto, and small enough to fit an Int32
            "-4242",                          // empty device half
            "device-",                        // empty process half
            "device-42x",                     // process half is not all digits
            "device-４２",                     // full-width digits are not a pid spelling
            "device-0",                       // pid 0 is the kernel, never an advertiser
            "device-0042",                    // a pid is never written with leading zeros
            "device-99999999999",             // wider than pid_t
        ]
    )
    func refusesIdentifiersThatCarryNoDeviceIdentity(identifier: String) {
        let source = RuntimeSource.bonjour(name: "Some Name", identifier: .init(rawValue: identifier), role: .client)
        #expect(RuntimeBookmarkScope.recovered(from: source) == nil)
    }

    @Test("This app's own Bonjour advertisement recovers nothing")
    func serverRoleBonjourRecoversNothing() {
        // A server-role source is the local advertisement; its identifier is the
        // service name. It is the broadcast end, not a peer being browsed.
        let source = RuntimeSource.bonjour(
            name: "JHs-Mac (RuntimeViewer)",
            identifier: "JHs-Mac (RuntimeViewer)",
            role: .server
        )
        #expect(RuntimeBookmarkScope.recovered(from: source) == nil)
    }

    @Test("A directly built Bonjour scope matches the one recovered from the same peer's source")
    func directConstructionAgreesWithRecovery() throws {
        // This equivalence is what makes migration work: bookmarks filed under
        // the key the migration derives from disk must be the same key the live
        // engine asks for. Both halves are modelled here the way
        // `RuntimeEngineManager` builds them.
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let processIdentifier = 4242
        let publishedProcessName = "SpringBoard"
        let serviceName = "JHs-iPhone (SpringBoard)"

        let endpointKey = "\(deviceIdentifier)-\(processIdentifier)"
        let engineName = publishedProcessName  // `endpoint.processName ?? endpoint.name`

        let directScope = try #require(
            RuntimeBookmarkScope.bonjour(deviceID: deviceIdentifier, processName: engineName, role: .client)
        )
        let recoveredScope = RuntimeBookmarkScope.recovered(
            from: .bonjour(name: engineName, identifier: .init(rawValue: endpointKey), role: .client)
        )
        #expect(directScope == recoveredScope)

        // And when the peer publishes a device ID but no process name, the
        // engine is named with the service name, and the two still agree.
        let fallbackDirectScope = try #require(
            RuntimeBookmarkScope.bonjour(deviceID: deviceIdentifier, processName: serviceName, role: .client)
        )
        let fallbackRecoveredScope = RuntimeBookmarkScope.recovered(
            from: .bonjour(name: serviceName, identifier: .init(rawValue: endpointKey), role: .client)
        )
        #expect(fallbackDirectScope == fallbackRecoveredScope)
    }

    @Test("A peer publishing no device ID yields no scope")
    func missingDeviceIdentifierYieldsNoScope() {
        #expect(RuntimeBookmarkScope.bonjour(deviceID: nil, processName: "SpringBoard", role: .client) == nil)
        #expect(RuntimeBookmarkScope.bonjour(deviceID: "", processName: "SpringBoard", role: .client) == nil)
    }
}

// MARK: - Legacy fallback, per consumer

@Suite("RuntimeBookmarkScope legacy fallback")
struct RuntimeBookmarkScopeLegacyFallbackTests {
    @Test("The bookmark key falls back to the identifier, leaving today's behaviour unchanged")
    func bookmarkKeyFallsBackToIdentifier() {
        let source = RuntimeSource.bonjour(name: "SpringBoard", identifier: "JHs-iPhone (RuntimeViewer)", role: .client)
        #expect(RuntimeBookmarkScope.legacy(for: source).bookmarkKey == source.identifier)
    }

    @Test("The sidebar key falls back to the display name, never the identifier")
    func sidebarKeyFallsBackToDisplayName() {
        // The identifier is the pid-bearing one after simulator-injection
        // landed. Handing it to the sidebar would give the peer a fresh set of
        // `NSOutlineView` autosave keys on every relaunch, accumulating in
        // `UserDefaults` forever — the failure this whole type exists to stop.
        let source = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-4242",
            role: .client
        )
        let scope = RuntimeBookmarkScope.legacy(for: source)
        #expect(scope.sidebarAutosaveKey == source.description)
        #expect(scope.sidebarAutosaveKey != source.identifier)
        #expect(!scope.sidebarAutosaveKey.contains("4242"))
    }

    @Test("The two consumers get genuinely different keys")
    func consumersDoNotShareOneFallbackKey() {
        let source = RuntimeSource.bonjour(
            name: "SpringBoard",
            identifier: "11111111-2222-3333-4444-555555555555-4242",
            role: .client
        )
        let scope = RuntimeBookmarkScope.legacy(for: source)
        #expect(scope.bookmarkKey != scope.sidebarAutosaveKey)
    }

    @Test("An identified scope gives both consumers the same key")
    func identifiedScopeSharesOneKey() {
        let scope = RuntimeBookmarkScope.identified(.bonjour(deviceID: "DEVICE", processName: "SpringBoard", role: .client))
        #expect(scope.bookmarkKey == scope.sidebarAutosaveKey)
        #expect(scope.bookmarkKey == "v1:bonjour:client:DEVICE:SpringBoard")
    }

    @Test("Only an identified scope has something to put on the wire")
    func onlyIdentifiedScopesTravel() {
        #expect(RuntimeBookmarkScope.identified(.local).identityRawValue == "v1:local::")
        #expect(RuntimeBookmarkScope.legacy(bookmarkKey: "a", sidebarAutosaveKey: "b").identityRawValue == nil)
    }
}

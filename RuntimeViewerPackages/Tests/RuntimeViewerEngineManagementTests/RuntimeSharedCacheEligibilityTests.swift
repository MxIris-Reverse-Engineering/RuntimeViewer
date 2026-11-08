#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// Which engines may borrow the shared cache images My Mac and Mac Catalyst
/// keep: a process attached on this Mac, unless it maps another cache.
@Suite("Shared cache eligibility")
struct RuntimeSharedCacheEligibilityTests {
    private static func eligibility(isTranslated: Bool?, environment: [String: String]?) -> RuntimeSharedCacheEligibility {
        RuntimeSharedCacheEligibility(isTranslated: { _ in isTranslated }, environment: { _ in environment })
    }

    private static let nativeProcess = eligibility(isTranslated: false, environment: [:])

    @Test(
        "A process attached on this Mac borrows",
        arguments: [
            RuntimeSource.remote(name: "Finder", identifier: "613", role: .client),
            RuntimeSource.localSocket(name: "Notes", identifier: "1234", role: .client),
        ]
    )
    func attachedProcessesBorrow(source: RuntimeSource) {
        #expect(Self.nativeProcess.isEligible(source))
    }

    @Test(
        "Any other engine does not borrow through this rule",
        arguments: [
            RuntimeSource.local,
            RuntimeSource.macCatalystClient,
            RuntimeSource.remote(name: "Finder", identifier: "613", role: .server),
            RuntimeSource.localSocket(name: "Notes", identifier: "not a process", role: .client),
            RuntimeSource.bonjour(name: "iPhone", identifier: "iPhone-1", role: .client),
            RuntimeSource.injectedTCP(name: "SpringBoard", host: "192.168.1.2", port: 8000, identifier: "claim", role: .client),
            RuntimeSource.directTCP(name: "Peer", host: "192.168.1.3", port: 8001, role: .client),
            RuntimeSource.file(name: "Numbers", url: URL(fileURLWithPath: "/Applications/Numbers.app")),
        ]
    )
    func otherEnginesDoNotBorrow(source: RuntimeSource) {
        #expect(!Self.nativeProcess.isEligible(source))
    }

    @Test("A process running under Rosetta maps the x86_64 cache and does not borrow")
    func translatedProcessDoesNotBorrow() {
        let eligibility = Self.eligibility(isTranslated: true, environment: [:])

        #expect(!eligibility.isEligible(.remote(name: "Legacy", identifier: "700", role: .client)))
    }

    @Test("A process the kernel no longer has does not borrow")
    func goneProcessDoesNotBorrow() {
        let eligibility = Self.eligibility(isTranslated: nil, environment: nil)

        #expect(!eligibility.isEligible(.remote(name: "Gone", identifier: "701", role: .client)))
    }

    @Test(
        "A process told to map a private shared cache does not borrow",
        arguments: ["DYLD_SHARED_REGION", "DYLD_SHARED_CACHE_DIR"]
    )
    func privateSharedCacheDoesNotBorrow(variable: String) {
        let eligibility = Self.eligibility(isTranslated: false, environment: [variable: "private"])

        #expect(!eligibility.isEligible(.remote(name: "Experiment", identifier: "702", role: .client)))
    }

    @Test("A process whose environment cannot be read borrows")
    func unreadableEnvironmentBorrows() {
        let eligibility = Self.eligibility(isTranslated: false, environment: nil)

        #expect(eligibility.isEligible(.remote(name: "Other User", identifier: "703", role: .client)))
    }

    @Test("This test process runs natively, so it can share its shared cache")
    func thisProcessShares() {
        #expect(RuntimeSharedCacheEligibility.live.sharesThisProcessSharedCache())
    }
}

#endif

import Foundation
import Testing
@testable import RuntimeViewerCommunication

/// Contract suite for the advertised process display name.
///
/// History: this fallback chain existed twice — once here and once privately in
/// `RuntimeViewerServer` — and the two disagreed. Only this copy treated a
/// present-but-empty key as absent, so a target declaring
/// `CFBundleDisplayName = ""` was named correctly over Bonjour and named the
/// empty string over XPC and localSocket. Empty display names are not
/// hypothetical: several shipping apps ship one.
@Suite("ProcessNameFallback")
struct ProcessNameFallbackTests {
    @Test("A display name wins when it has content")
    func displayNameWins() {
        #expect(
            RuntimeNetworkBonjour.processName(displayName: "Finder", bundleName: "FinderKit", fallback: "finder") == "Finder"
        )
    }

    @Test("An empty display name falls through to the bundle name")
    func emptyDisplayNameFallsThrough() {
        #expect(
            RuntimeNetworkBonjour.processName(displayName: "", bundleName: "FinderKit", fallback: "finder") == "FinderKit"
        )
    }

    @Test("An absent display name falls through to the bundle name")
    func absentDisplayNameFallsThrough() {
        #expect(
            RuntimeNetworkBonjour.processName(displayName: nil, bundleName: "FinderKit", fallback: "finder") == "FinderKit"
        )
    }

    @Test("Both keys empty falls through to the process name")
    func bothEmptyFallsThroughToProcessName() {
        #expect(
            RuntimeNetworkBonjour.processName(displayName: "", bundleName: "", fallback: "finder") == "finder"
        )
    }

    @Test("Both keys absent falls through to the process name")
    func bothAbsentFallsThroughToProcessName() {
        #expect(
            RuntimeNetworkBonjour.processName(displayName: nil, bundleName: nil, fallback: "finder") == "finder"
        )
    }
}

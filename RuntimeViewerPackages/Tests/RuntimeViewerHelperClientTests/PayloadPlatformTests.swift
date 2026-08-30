#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerHelperClient

/// Contract suite for `PayloadPlatform` — which slice a given target gets, and
/// where it is installed.
///
/// History: every target used to receive `/Library/Frameworks/RuntimeViewerServer.framework`,
/// the macOS slice. An iOS Simulator process refuses it, and the daemon's remap
/// fallback then killed the process outright. The mapping below is what stands
/// between a target and the wrong slice.
@Suite("PayloadPlatform")
struct PayloadPlatformTests {
    @Test("A macOS target gets the macOS slice")
    func macOSTargetGetsMacOSSlice() {
        #expect(PayloadPlatform(targetPlatform: .macOS) == .macOS)
    }

    @Test("A Catalyst target keeps getting the macOS slice")
    func catalystTargetKeepsMacOSSlice() {
        // Catalyst runs on the host's dyld and shared cache and has always been
        // given this slice; pinned so the platform rework does not change it as
        // a side effect.
        #expect(PayloadPlatform(targetPlatform: .macCatalyst) == .macOS)
    }

    @Test("An iOS Simulator target gets the simulator slice")
    func simulatorTargetGetsSimulatorSlice() {
        #expect(PayloadPlatform(targetPlatform: .iOSSimulator) == .iOSSimulator)
    }

    @Test("A target with no slice is refused rather than given the nearest one")
    func targetsWithoutASliceAreRefused() {
        // These are real processes that show up in the Attach list on a Mac
        // running the corresponding simulator. Handing them the macOS slice is
        // how the payload used to reach dyld — and the remap fallback the
        // process died to.
        #expect(PayloadPlatform(targetPlatform: .tvOSSimulator) == nil)
        #expect(PayloadPlatform(targetPlatform: .watchOSSimulator) == nil)
        #expect(PayloadPlatform(targetPlatform: .visionOSSimulator) == nil)
        #expect(PayloadPlatform(targetPlatform: .unsupported(2)) == nil)
    }

    @Test("The two slices install as distinct siblings")
    func slicesInstallSideBySide() {
        // They are the same architecture and differ only in platform, so one
        // fat binary cannot hold both; distinct bundle names are what keeps the
        // simulator slice from overwriting the macOS one on install.
        let macOSURL = PayloadPlatform.macOS.installedFrameworkURL
        let simulatorURL = PayloadPlatform.iOSSimulator.installedFrameworkURL

        #expect(macOSURL != simulatorURL)
        #expect(macOSURL.deletingLastPathComponent() == simulatorURL.deletingLastPathComponent())
        #expect(macOSURL.path == "/Library/Frameworks/RuntimeViewerServer.framework")
        #expect(simulatorURL.path == "/Library/Frameworks/RuntimeViewerMobileServer.framework")
    }

    @Test("Bundle names stay in sync with their base names")
    func bundleNamesAreDerived() {
        for platform in PayloadPlatform.allCases {
            #expect(platform.frameworkBundleName == "\(platform.frameworkBundleBaseName).framework")
            // `Bundle.main.url(forResource:withExtension:)` takes the base name,
            // so a base name that already carried the extension would look up
            // "…framework.framework" and silently find nothing.
            #expect(!platform.frameworkBundleBaseName.hasSuffix(".framework"))
        }
    }
}

#endif

#if DEBUG

import Testing
@testable import RuntimeViewerCommunication

/// The Debug-arm64e variant has to be selected before anything reads `RuntimeViewerMachServiceName`,
/// because a reader may keep the name it was handed. The ordering itself is a property of process
/// startup and cannot be reproduced in a unit test; what is tested here is the detection that makes
/// a violation say so on the spot instead of surfacing as a failed helper install much later.
///
/// Exercised against `RuntimeViewerVariantSelection` rather than the global, so the suite owns its
/// state and stays parallel-safe.
@Suite("RuntimeViewerVariantSelection")
struct VariantSelectionOrderingTests {
    @Test("Defaults to the non-arm64e daemon")
    func defaultsToNonARM64EDaemon() {
        var selection = RuntimeViewerVariantSelection()
        #expect(selection.selectedIsARM64EVariant == false)
        #expect(selection.readMachServiceName() == "dev.mxiris.runtimeviewer.service")
    }

    @Test("Selecting the arm64e variant before any read switches the daemon")
    func selectingBeforeAnyReadSwitchesDaemon() {
        var selection = RuntimeViewerVariantSelection()
        let diagnosticMessage = selection.select(isARM64EVariant: true)

        #expect(diagnosticMessage == nil)
        #expect(selection.selectedIsARM64EVariant == true)
        #expect(selection.readMachServiceName() == "dev.arm64e.mxiris.runtimeviewer.service")
    }

    @Test("Selecting the arm64e variant after a read is reported, and names what was handed out")
    func selectingAfterAReadIsReported() {
        var selection = RuntimeViewerVariantSelection()
        let handedOutName = selection.readMachServiceName()

        let diagnosticMessage = selection.select(isARM64EVariant: true)

        #expect(diagnosticMessage != nil)
        // The name a reader may still be holding is the actionable half of the diagnostic.
        #expect(diagnosticMessage?.contains(handedOutName) == true)
        // The selection still takes effect: later readers get the right name, which is exactly why
        // the mismatch is otherwise invisible.
        #expect(selection.readMachServiceName() == "dev.arm64e.mxiris.runtimeviewer.service")
    }

    @Test("Re-selecting the variant already in effect after a read is not reported")
    func reselectingTheSameVariantAfterAReadIsNotReported() {
        var selection = RuntimeViewerVariantSelection()
        _ = selection.select(isARM64EVariant: true)
        _ = selection.readMachServiceName()

        #expect(selection.select(isARM64EVariant: true) == nil)
    }

    @Test("Leaving the variant unselected after a read is not reported")
    func leavingTheVariantUnselectedAfterAReadIsNotReported() {
        var selection = RuntimeViewerVariantSelection()
        _ = selection.readMachServiceName()

        #expect(selection.select(isARM64EVariant: false) == nil)
    }

    @Test("The global mach service name is the selection's name")
    func globalMachServiceNameMatchesTheSelection() {
        // Read-only, so it stays safe next to tests running in parallel: proves the global name is
        // produced by the type above rather than by a second copy of the rule.
        #expect(
            RuntimeViewerMachServiceName
                == RuntimeViewerVariantSelection.machServiceName(isARM64EVariant: runtimeViewerIsARM64EVariant)
        )
    }
}

#endif

import Testing
import Foundation
@testable import RuntimeViewerApplication

/// Contract suite for how a just-injected simulator payload is recognised.
///
/// History: the wait after injecting a simulator process matched the endpoint
/// key's trailing dash-separated component against the pid, discarding the
/// device half of `{deviceID}-{pid}`. pid namespaces are per device, so any
/// peer on the network advertising a process with the same pid satisfied the
/// wait — reporting a successful attach for a payload that never started.
@Suite("InjectedBonjourEngineMatching")
@MainActor
struct InjectedBonjourEngineMatchingTests {
    private let targetDeviceID = "20DAFF33-83CA-4C2F-AD0E-809B05501803"
    private let foreignDeviceID = "11111111-2222-3333-4444-555555555555"

    @Test("The engine on the target device is selected")
    func targetDeviceIsSelected() {
        let target = "\(targetDeviceID)-1234"
        #expect(
            RuntimeEngineManager.injectedBonjourEngineIdentifier(
                among: ["\(foreignDeviceID)-1234", target],
                deviceID: targetDeviceID,
                processIdentifier: 1234
            ) == target
        )
    }

    @Test("Another device advertising the same pid is not mistaken for the target")
    func foreignDeviceWithSamePidIsRejected() {
        // The regression this suite exists for. Under the trailing-component
        // rule this returned the foreign engine and the attach reported success.
        #expect(
            RuntimeEngineManager.injectedBonjourEngineIdentifier(
                among: ["\(foreignDeviceID)-1234"],
                deviceID: targetDeviceID,
                processIdentifier: 1234
            ) == nil
        )
    }

    @Test("A different pid on the target device is not mistaken for the target")
    func sameDeviceDifferentPidIsRejected() {
        #expect(
            RuntimeEngineManager.injectedBonjourEngineIdentifier(
                among: ["\(targetDeviceID)-99"],
                deviceID: targetDeviceID,
                processIdentifier: 1234
            ) == nil
        )
    }

    @Test("A pid that is a suffix of another pid is not mistaken for the target")
    func pidSuffixIsRejected() {
        // `-1234` is a suffix of `-41234`. Whole-key equality is what rules it
        // out; a `hasSuffix` check would not.
        #expect(
            RuntimeEngineManager.injectedBonjourEngineIdentifier(
                among: ["\(targetDeviceID)-41234"],
                deviceID: targetDeviceID,
                processIdentifier: 1234
            ) == nil
        )
    }

    @Test("An endpoint key from a peer predating the TXT keys is not matched")
    func legacyServiceNameIsRejected() {
        // Peers that publish neither `rv-device-id` nor `rv-proc-pid` fall back
        // to their service name as the key. Those are never injection targets
        // of ours, and must not satisfy the wait.
        #expect(
            RuntimeEngineManager.injectedBonjourEngineIdentifier(
                among: ["JH's iPhone"],
                deviceID: targetDeviceID,
                processIdentifier: 1234
            ) == nil
        )
    }
}

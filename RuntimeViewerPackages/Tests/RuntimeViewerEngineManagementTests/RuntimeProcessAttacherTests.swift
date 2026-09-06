#if os(macOS)

import Foundation
import Testing
import RuntimeViewerHelperClient
@testable import RuntimeViewerEngineManagement

/// Contract suite for how `RuntimeProcessAttacher` decides the transport a
/// target is reached through.
///
/// The decision is the part of the attach flow that used to be inline in
/// `AttachToProcessViewModel` and had no test: everything after it needs the
/// helper daemon and a live target, everything in it is a function of the
/// payload slice and two probes.
@Suite("RuntimeProcessAttacher")
@MainActor
struct RuntimeProcessAttacherTests {
    private let target = RuntimeProcessAttacher.Target(name: "Finder", processIdentifier: 4321)
    private let simulatorDeviceID = "20DAFF33-83CA-4C2F-AD0E-809B05501803"

    private func route(
        payloadPlatform: PayloadPlatform,
        isMachLookupBlocked: Bool = false,
        environment: [String: String]? = nil
    ) throws -> RuntimeProcessAttacher.Route {
        try RuntimeProcessAttacher.route(
            for: target,
            payloadPlatform: payloadPlatform,
            sandboxProbe: { _ in isMachLookupBlocked },
            environmentProbe: { _ in environment }
        )
    }

    @Test("A Mac target that can look up the Mach service is reached over XPC")
    func macTargetWithMachLookupUsesXPC() throws {
        #expect(try route(payloadPlatform: .macOS, isMachLookupBlocked: false) == .xpc)
    }

    @Test("A Mac target whose sandbox denies mach-lookup falls back to the localhost socket")
    func sandboxedMacTargetUsesLocalSocket() throws {
        #expect(try route(payloadPlatform: .macOS, isMachLookupBlocked: true) == .localSocket)
    }

    @Test("A simulator target is reached over Bonjour on the device its environment names")
    func simulatorTargetUsesBonjourOnItsDevice() throws {
        #expect(
            try route(payloadPlatform: .iOSSimulator, environment: ["SIMULATOR_UDID": simulatorDeviceID])
                == .simulatorBonjour(deviceID: simulatorDeviceID)
        )
    }

    @Test("A simulator target never consults the sandbox probe")
    func simulatorTargetSkipsSandboxProbe() throws {
        // The probe chooses between XPC and the socket; a simulator payload
        // takes neither, so asking would be a wasted kernel round-trip at best
        // and a wrong answer at worst.
        var probed = false
        _ = try RuntimeProcessAttacher.route(
            for: target,
            payloadPlatform: .iOSSimulator,
            sandboxProbe: { _ in
                probed = true
                return true
            },
            environmentProbe: { _ in ["SIMULATOR_UDID": simulatorDeviceID] }
        )
        #expect(probed == false)
    }

    @Test("A simulator target whose device cannot be identified is refused before anything is installed", arguments: [
        nil,
        [:],
        ["SIMULATOR_UDID": ""],
    ] as [[String: String]?])
    func simulatorTargetWithoutDeviceIsRefused(environment: [String: String]?) {
        #expect {
            try route(payloadPlatform: .iOSSimulator, environment: environment)
        } throws: { error in
            guard case RuntimeEngineManager.AttachedEngineHandshakeError.simulatorDeviceUnidentifiable(let name, let processIdentifier) = error else {
                return false
            }
            return name == target.name && processIdentifier == target.processIdentifier
        }
    }

    @Test("Every route reports the transport the outcome will carry")
    func routesMapToTransports() {
        #expect(RuntimeProcessAttacher.Route.xpc.transport == .xpc)
        #expect(RuntimeProcessAttacher.Route.localSocket.transport == .localSocket)
        #expect(RuntimeProcessAttacher.Route.simulatorBonjour(deviceID: simulatorDeviceID).transport == .simulatorBonjour)
    }
}

#endif

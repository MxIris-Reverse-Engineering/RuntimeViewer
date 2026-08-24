#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerHelperClient

/// Contract suite for `ProcessEnvironmentProbe`.
///
/// The probe exists because a simulator process is an ordinary host process:
/// its pid is drawn from the Mac's single pid namespace and says nothing about
/// which simulator booted it. `SIMULATOR_UDID` in the target's environment is
/// the only answer, and reading it is what lets an injected payload's Bonjour
/// advertisement be recognised by device *and* pid rather than by pid alone.
@Suite("ProcessEnvironmentProbe")
struct ProcessEnvironmentProbeTests {
    @Test("This process's environment is read back")
    func ownEnvironmentIsReadable() throws {
        let probed = try #require(ProcessEnvironmentProbe.environment(ofProcess: getpid()))
        let actual = ProcessInfo.processInfo.environment
        // Not compared wholesale: the test runner's own environment can carry
        // entries the kernel blob orders differently. Every key the probe finds
        // must agree with Foundation, and PATH must be among them.
        #expect(!probed.isEmpty)
        #expect(probed["PATH"] == actual["PATH"])
        for (key, value) in probed where actual[key] != nil {
            #expect(actual[key] == value, "environment disagreed for \(key)")
        }
    }

    @Test("A pid nobody owns yields no answer")
    func unknownProcessYieldsNil() {
        #expect(ProcessEnvironmentProbe.environment(ofProcess: 0) == nil)
    }

    @Test("Arguments are skipped rather than parsed as environment entries")
    func argumentsAreNotMistakenForEnvironment() throws {
        // An argument containing '=' is the reason argc is honoured instead of
        // scanning for the first thing that looks like a KEY=VALUE pair.
        let blob = ArgumentBlob.make(
            executablePath: "/usr/bin/tool",
            arguments: ["/usr/bin/tool", "--flag=not-an-environment-entry"],
            environment: ["SIMULATOR_UDID=20DAFF33-83CA-4C2F-AD0E-809B05501803", "PATH=/usr/bin"]
        )
        let environment = try #require(ProcessEnvironmentProbe.environment(fromArgumentBlob: blob))
        #expect(environment["SIMULATOR_UDID"] == "20DAFF33-83CA-4C2F-AD0E-809B05501803")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["--flag"] == nil)
        #expect(environment.count == 2)
    }

    @Test("A blob too short to hold argc yields no answer")
    func truncatedBlobYieldsNil() {
        #expect(ProcessEnvironmentProbe.environment(fromArgumentBlob: [0, 0]) == nil)
    }

    @Test("An environment entry without '=' is skipped rather than guessed at")
    func malformedEntryIsSkipped() throws {
        let blob = ArgumentBlob.make(
            executablePath: "/usr/bin/tool",
            arguments: ["/usr/bin/tool"],
            environment: ["JUST_A_NAME", "SIMULATOR_UDID=ABC"]
        )
        let environment = try #require(ProcessEnvironmentProbe.environment(fromArgumentBlob: blob))
        #expect(environment == ["SIMULATOR_UDID": "ABC"])
    }
}

/// Builds the `KERN_PROCARGS2` layout by hand.
private enum ArgumentBlob {
    static func make(executablePath: String, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array(executablePath.utf8) + [0]
        // The kernel pads the executable path out with extra NULs; include a
        // couple so the parser's padding skip is exercised.
        bytes += [0, 0]
        for argument in arguments {
            bytes += Array(argument.utf8) + [0]
        }
        for entry in environment {
            bytes += Array(entry.utf8) + [0]
        }
        return bytes
    }
}

#endif

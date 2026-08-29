#if os(macOS)

import Foundation

/// Reads another process's environment variables.
///
/// Exists to recover an injection target's `SIMULATOR_UDID`. A simulator
/// process is an ordinary host process — same pid namespace as everything else
/// on the Mac — so nothing about the pid says which simulator it belongs to,
/// and CoreSimulator puts the answer in the environment of every process it
/// boots.
///
/// Reads succeed for processes running as the same user. The kernel refuses
/// `KERN_PROCARGS2` for others, which surfaces here as `nil` rather than as an
/// error: the caller cannot do anything about it either way.
public enum ProcessEnvironmentProbe {
    /// The environment of `processIdentifier`, or `nil` when it cannot be read.
    public static func environment(ofProcess processIdentifier: pid_t) -> [String: String]? {
        guard let buffer = processArgumentBlob(ofProcess: processIdentifier) else { return nil }
        return environment(fromArgumentBlob: buffer)
    }

    /// The raw `KERN_PROCARGS2` blob.
    ///
    /// Layout: a 32-bit `argc`, the executable path, NUL padding, `argc`
    /// argument strings, then the environment — everything after the first
    /// four bytes NUL-separated.
    private static func processArgumentBlob(ofProcess processIdentifier: pid_t) -> [UInt8]? {
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var bufferSize = 0
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), nil, &bufferSize, nil, 0) == 0,
              bufferSize > 0
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), &buffer, &bufferSize, nil, 0) == 0
        else { return nil }
        return Array(buffer.prefix(bufferSize))
    }

    /// Splits an argument blob into its environment entries.
    ///
    /// Internal rather than private so the parsing can be tested against a
    /// hand-built blob — the shapes that matter (a truncated blob, a missing
    /// `=`) are impossible to provoke from a live process.
    static func environment(fromArgumentBlob buffer: [UInt8]) -> [String: String]? {
        let argumentCountWidth = MemoryLayout<Int32>.size
        guard buffer.count > argumentCountWidth else { return nil }
        let argumentCount = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        guard argumentCount >= 0 else { return nil }

        var index = argumentCountWidth
        // The executable path, then however many NULs the kernel padded it with.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        // Then exactly `argc` argument strings, which are skipped rather than
        // parsed: an argument may well contain an `=` and would otherwise be
        // mistaken for an environment entry.
        var skippedArguments = Int32(0)
        while skippedArguments < argumentCount, index < buffer.count {
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1
            skippedArguments += 1
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            let entryStart = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            // An empty entry terminates the environment block.
            if entryStart == index { break }
            if let entry = String(bytes: buffer[entryStart ..< index], encoding: .utf8),
               let separator = entry.firstIndex(of: "=") {
                environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
            }
            index += 1
        }
        return environment
    }
}

#endif

#if os(macOS)

import Foundation

/// Whether System Integrity Protection is off, which attaching to a process on this Mac needs.
public enum SIPChecker {
    public static func isDisabled() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/csrutil"
        task.arguments = ["status"]

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let output = String(data: data, encoding: .utf8) else { return false }

        return output.contains("disabled")
    }
}

#endif

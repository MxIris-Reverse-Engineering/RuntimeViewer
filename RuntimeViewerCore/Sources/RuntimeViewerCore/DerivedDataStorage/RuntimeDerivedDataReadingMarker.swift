import Foundation

/// The file a read puts beside a container — `<container>.reading` — and
/// takes away only once what it read has been walked through, so that a
/// container which takes the process down is not read again.
///
/// A container that passes every check can still hold something the code
/// reading it traps on — a check missed, a reader that changed. The serving
/// process reads at launch and at every reconnection, so one such file would
/// crash "My Mac" over and over. The marker breaks the loop: a marker whose
/// process is gone means the last read never finished, and the container is
/// deleted unread.
///
/// It names its process by identifier and start time, so another process
/// reading the same file — two instances of one build — is told from a read
/// that died, and a later process that happens to get the same identifier
/// is not taken for the reader.
struct RuntimeDerivedDataReadingMarker: Hashable, Sendable {
    static let fileExtension = "reading"

    let processIdentifier: Int32

    /// Microseconds since 1970; zero where the process's start time cannot
    /// be read.
    let processStartTime: UInt64

    init(processIdentifier: Int32, processStartTime: UInt64) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
    }

    static func currentProcess() -> RuntimeDerivedDataReadingMarker {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        return RuntimeDerivedDataReadingMarker(processIdentifier: processIdentifier, processStartTime: startTime(ofProcess: processIdentifier) ?? 0)
    }

    static func url(forContainerAt containerURL: URL) -> URL {
        containerURL.appendingPathExtension(fileExtension)
    }

    /// `nil` when there is no marker, or what is there is not one.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let processIdentifier = Int32(fields[0]),
              let processStartTime = UInt64(fields[1])
        else { return nil }
        self.init(processIdentifier: processIdentifier, processStartTime: processStartTime)
    }

    func write(to url: URL) throws {
        try Data("\(processIdentifier) \(processStartTime)\n".utf8).write(to: url, options: .atomic)
    }

    /// Whether the process that wrote the marker still runs: one with its
    /// identifier exists, and started when it did.
    static func isProcessRunning(_ marker: RuntimeDerivedDataReadingMarker) -> Bool {
        guard marker.processIdentifier > 0 else { return false }
        guard kill(marker.processIdentifier, 0) == 0 || errno == EPERM else { return false }
        guard let startTime = startTime(ofProcess: marker.processIdentifier) else {
            // Alive, but its start time cannot be read here: take it for the
            // reader rather than delete a file it may be reading.
            return true
        }
        return marker.processStartTime == 0 || startTime == marker.processStartTime
    }

    private static func startTime(ofProcess processIdentifier: Int32) -> UInt64? {
        #if os(macOS)
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), &information, &size, nil, 0) == 0,
              size > 0
        else { return nil }
        let startTime = information.kp_proc.p_un.__p_starttime
        return UInt64(startTime.tv_sec) * 1_000_000 + UInt64(startTime.tv_usec)
        #else
        return nil
        #endif
    }
}

import Darwin
import Foundation

/// Where the tool writes. Injected so tests can capture what a command prints.
public struct OutputStreams: Sendable {
    public var writeStandardOutput: @Sendable (String) -> Void
    public var writeStandardError: @Sendable (String) -> Void
    /// Standard error is a terminal, so progress may redraw one line.
    public var standardErrorIsTerminal: Bool

    public init(writeStandardOutput: @escaping @Sendable (String) -> Void, writeStandardError: @escaping @Sendable (String) -> Void, standardErrorIsTerminal: Bool) {
        self.writeStandardOutput = writeStandardOutput
        self.writeStandardError = writeStandardError
        self.standardErrorIsTerminal = standardErrorIsTerminal
    }

    public static let standard = OutputStreams(
        writeStandardOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeStandardError: { FileHandle.standardError.write(Data($0.utf8)) },
        standardErrorIsTerminal: isatty(STDERR_FILENO) != 0
    )

    /// Streams that collect into a ``CapturedOutput``.
    public static func capturing() -> (streams: OutputStreams, captured: CapturedOutput) {
        let captured = CapturedOutput()
        let streams = OutputStreams(
            writeStandardOutput: { captured.appendStandardOutput($0) },
            writeStandardError: { captured.appendStandardError($0) },
            standardErrorIsTerminal: false
        )
        return (streams, captured)
    }
}

public final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutputStorage = ""
    private var standardErrorStorage = ""

    public var standardOutput: String {
        lock.withLock { standardOutputStorage }
    }

    public var standardError: String {
        lock.withLock { standardErrorStorage }
    }

    func appendStandardOutput(_ text: String) {
        lock.withLock { standardOutputStorage += text }
    }

    func appendStandardError(_ text: String) {
        lock.withLock { standardErrorStorage += text }
    }
}

import Darwin
import Foundation

/// A process `attach` can target.
public struct RunningProcess: Sendable, Hashable {
    public let processIdentifier: Int32
    /// The kernel's name for the process (`proc_name`): the app name for an
    /// app, the executable name for a daemon.
    public let name: String
    public let executablePath: String?

    public init(processIdentifier: Int32, name: String, executablePath: String?) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.executablePath = executablePath
    }

    /// Whether `query` names this process: the process name or the
    /// executable's file name, compared case-insensitively.
    public func matches(name query: String) -> Bool {
        let wanted = query.lowercased()
        if name.lowercased() == wanted {
            return true
        }
        guard let executablePath else { return false }
        return (executablePath as NSString).lastPathComponent.lowercased() == wanted
    }
}

/// Lists the processes on this machine. `attach <name>` and the name shown
/// for `attach <pid>` come from here; tests substitute a fixed list.
public protocol ProcessDirectory: Sendable {
    func runningProcesses() -> [RunningProcess]
    func process(withIdentifier processIdentifier: Int32) -> RunningProcess?
}

/// Asks the kernel through libproc. Needs no helper and no AppKit; processes
/// of other users may come back without a path, never without a name.
public struct LibprocProcessDirectory: ProcessDirectory {
    public init() {}

    public func runningProcesses() -> [RunningProcess] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Processes start between the two calls; leave room for them.
        var identifiers = [pid_t](repeating: 0, count: Int(count) * 2)
        count = proc_listallpids(&identifiers, Int32(identifiers.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return identifiers.prefix(Int(count)).compactMap { processIdentifier in
            guard processIdentifier > 0 else { return nil }
            return process(withIdentifier: processIdentifier)
        }
    }

    public func process(withIdentifier processIdentifier: Int32) -> RunningProcess? {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = proc_name(processIdentifier, &nameBuffer, UInt32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        let name = String(cString: nameBuffer)

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath = pathLength > 0 ? String(cString: pathBuffer) : nil
        return RunningProcess(processIdentifier: processIdentifier, name: name, executablePath: executablePath)
    }
}

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI

/// Supplies the process picker with the process table of the machine an engine belongs to,
/// and keeps what that machine said about injecting each entry.
///
/// The verdict is kept here rather than carried by the rows because the picker's row type
/// describes a process, not a judgement about one — and the judgement is not the host's to
/// make. Only the far end knows its own uid, entitlements and daemon state; measured, a
/// jailbroken build running as uid 501 cannot inject a uid 0 process. So the verdict
/// travels with the list and is answered back through the picker's `shouldSelect` call,
/// which dims the row and refuses the selection.
@MainActor
final class RemoteProcessItemSource {
    private let runtimeEngine: RuntimeEngine

    private var injectabilityByProcessIdentifier: [pid_t: RuntimeProcess.Injectability] = [:]

    init(runtimeEngine: RuntimeEngine) {
        self.runtimeEngine = runtimeEngine
    }

    /// The display name of the machine being listed, for the picker's title.
    var machineName: String {
        runtimeEngine.source.description
    }

    func makeItemSource() -> AnyRunningItemSource<RunningProcess> {
        // Captured out of the actor-isolated property before the closure, which is
        // `@Sendable` and cannot read it.
        let runtimeEngine = runtimeEngine
        return AnyRunningItemSource { [weak self] in
            let processes = try await runtimeEngine.processList()
            // Recorded before the rows are handed over, so the first `shouldSelect` the
            // picker makes already has a verdict to answer with.
            await self?.record(processes)
            return processes.map(RunningProcess.init(remoteProcess:))
        }
    }

    /// Whether the far end said this process can be injected.
    ///
    /// An unknown identifier answers `false`. That covers the window before the list
    /// arrives, and it is the safe direction: offering a target the far end never vouched
    /// for would end in an injection failure instead of a dimmed row.
    func isInjectable(processIdentifier: pid_t) -> Bool {
        injectabilityByProcessIdentifier[processIdentifier]?.isInjectable ?? false
    }

    private func record(_ processes: [RuntimeProcess]) {
        injectabilityByProcessIdentifier = Dictionary(
            processes.map { ($0.processIdentifier, $0.injectability) },
            uniquingKeysWith: { firstVerdict, _ in firstVerdict },
        )
    }
}

extension RunningProcess {
    /// A picker row describing a process on another machine.
    ///
    /// Three fields are left at their empty values rather than guessed. There is no icon
    /// to fetch for a process on another device; the far end does not report the
    /// architecture the kernel runs it as; and sandbox status is not reported either —
    /// `false` renders as *no* sandbox badge, which is the honest showing of "not
    /// reported", because that badge only appears when the flag is set.
    ///
    /// `platform` is nil, and the remote picker leaves that field out of its configuration
    /// altogether: every process on one device shares a platform, so a column for it would
    /// distinguish nothing. The field exists to tell simulator processes from host ones on
    /// a Mac, which is not a question that arises here.
    init(remoteProcess: RuntimeProcess) {
        self.init(
            processIdentifier: remoteProcess.processIdentifier,
            name: remoteProcess.name,
            executablePath: remoteProcess.executablePath,
        )
    }
}

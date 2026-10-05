import AppKit
import UniformTypeIdentifiers
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
            // A second round trip, and necessarily after the first: the list is what says
            // which bundles there are to ask about. `RunningItemSource` hands over one
            // finished snapshot and the library has no "rows now, icons later" hook, so
            // this costs the picker's first paint one round trip — the price of the icons.
            //
            // Only the distinct bundles are asked for. A device's process table is mostly
            // daemons, which have no bundle at all, and the applications that remain
            // commonly run several processes against one bundle.
            let iconDataByApplicationBundlePath = await runtimeEngine.applicationIcons(
                forBundlesAtPaths: Self.distinctApplicationBundlePaths(in: processes),
            )
            return await Self.makeRows(
                for: processes,
                iconDataByApplicationBundlePath: iconDataByApplicationBundlePath,
            )
        }
    }

    private nonisolated static func distinctApplicationBundlePaths(in processes: [RuntimeProcess]) -> [String] {
        Array(Set(processes.compactMap(\.applicationBundlePath)))
    }

    /// The picker's rows, icons included.
    ///
    /// On the main actor because it builds `NSImage`s that go straight into a view.
    @MainActor
    private static func makeRows(
        for processes: [RuntimeProcess],
        iconDataByApplicationBundlePath: [String: Data],
    ) -> [RunningProcess] {
        // Decoded and masked once per bundle rather than once per row: `NSImage` is a
        // reference type, so an application's processes share the instance.
        //
        // The mask is not cosmetic polish on top of a correct image — the files in an
        // iOS bundle are square and fully opaque, and the rounded shape is something
        // the device applies when it draws them. Without it these rows show square
        // tiles next to the Mac's own rounded icons.
        let iconsByApplicationBundlePath = iconDataByApplicationBundlePath
            .compactMapValues(NSImage.init(data:))
            .mapValues(ApplicationIconMask.applied(to:))
        // What the local picker shows for a process whose executable has no extension,
        // which is every daemon. Leaving those rows blank would make the device's list
        // read as half-loaded rather than as a list of daemons.
        let genericExecutableIcon = NSWorkspace.shared.icon(for: .unixExecutable)
        return processes.map { process in
            RunningProcess(
                remoteProcess: process,
                icon: process.applicationBundlePath.flatMap { iconsByApplicationBundlePath[$0] }
                    ?? genericExecutableIcon,
            )
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
    /// Two fields are left at their empty values rather than guessed: the far end does
    /// not report the architecture the kernel runs it as, and sandbox status is not
    /// reported either — `false` renders as *no* sandbox badge, which is the honest
    /// showing of "not reported", because that badge only appears when the flag is set.
    ///
    /// `platform` is nil, and the remote picker leaves that field out of its configuration
    /// altogether: every process on one device shares a platform, so a column for it would
    /// distinguish nothing. The field exists to tell simulator processes from host ones on
    /// a Mac, which is not a question that arises here.
    ///
    /// The icon is passed in rather than derived from the process, because it comes from
    /// nothing this row carries: it is a file in the far end's own bundle, fetched by
    /// bundle and shared between that application's processes.
    init(remoteProcess: RuntimeProcess, icon: NSImage?) {
        self.init(
            processIdentifier: remoteProcess.processIdentifier,
            name: remoteProcess.name,
            executablePath: remoteProcess.executablePath,
            icon: icon,
        )
    }
}

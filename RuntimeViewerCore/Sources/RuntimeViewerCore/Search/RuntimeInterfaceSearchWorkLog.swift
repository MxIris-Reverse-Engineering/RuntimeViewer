import Foundation

/// Counts the costly steps of a search — the tables it builds to report a
/// hit — so a test can prove a shortcut skips them, where timing would only
/// suggest it.
///
/// Nothing binds `current` outside tests. Reading it unbound costs one
/// task-local lookup per costly step, which the step itself dwarfs.
final class RuntimeInterfaceSearchWorkLog: @unchecked Sendable {
    enum Step: Hashable, Sendable {
        /// Where the lines of one interface begin, for a hit to report.
        case lineTable
        /// The semantic kind of each span of one interface.
        case spanKindTable
    }

    @TaskLocal static var current: RuntimeInterfaceSearchWorkLog?

    private let lock = NSLock()

    private var countsByStep: [Step: Int] = [:]

    init() {}

    /// Records `step` in the log bound to the current task, if any.
    static func record(_ step: Step) {
        current?.add(step)
    }

    func count(of step: Step) -> Int {
        lock.withLock { countsByStep[step, default: 0] }
    }

    private func add(_ step: Step) {
        lock.withLock { countsByStep[step, default: 0] += 1 }
    }
}

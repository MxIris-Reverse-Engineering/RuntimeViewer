import Foundation
import FoundationToolbox

/// A flag that several paths race to set, of which only the first may act —
/// the state handlers, timeouts and listeners that can each resume the one
/// continuation a connection's setup waits on.
///
/// `@unchecked Sendable`: the one stored property is a `Mutex`.
final class RuntimeOnceFlag: @unchecked Sendable {
    private let isSet = Mutex(false)

    /// Sets the flag; `true` only for the call that set it.
    func claim() -> Bool {
        isSet.withLock { isSet in
            guard !isSet else { return false }
            isSet = true
            return true
        }
    }

    /// Whether some call has set the flag.
    var isClaimed: Bool {
        isSet.withLock { $0 }
    }
}

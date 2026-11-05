#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

extension NSLock {
    /// `NSLock.withLock(_:)` needs macOS 13; this module still declares 10.15.
    func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

#endif

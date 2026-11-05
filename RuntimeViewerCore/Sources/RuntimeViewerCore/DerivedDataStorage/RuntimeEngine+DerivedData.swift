import Foundation
import FoundationToolbox

extension RuntimeEngine {
    /// The derived data a corpus store of this process reads and writes:
    /// the process's store when derived data is on here, `nil` otherwise.
    static var processDerivedDataStore: RuntimeDerivedDataStore? {
        guard RuntimeDerivedData.isEnabledInThisProcess else { return nil }
        return RuntimeDerivedData.processStore
    }
}

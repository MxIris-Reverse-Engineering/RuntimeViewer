import Foundation
import FoundationToolbox
import RuntimeViewerCommunication

/// The `DYLD_ROOT_PATH` of the process that owns an engine's images: what
/// turns a path as a client spells it into the key the serving process keeps
/// it under.
final class RuntimeEngineDyldRootPath: Sendable {
    private let rootPath: Mutex<String?>

    init(_ rootPath: String?) {
        self.rootPath = Mutex(rootPath)
    }

    var value: String? {
        rootPath.withLock { $0 }
    }

    func update(_ newRootPath: String?) {
        rootPath.withLock { $0 = newRootPath }
    }
}

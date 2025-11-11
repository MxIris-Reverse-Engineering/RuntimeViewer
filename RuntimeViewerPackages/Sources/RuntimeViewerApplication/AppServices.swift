import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class AppServices: NSObject {
//    public static let shared = AppServices()

    public let runtimeEngineManager = RuntimeEngineManager()
    
    @Observed
    public var runtimeEngine: RuntimeEngine = .shared
}

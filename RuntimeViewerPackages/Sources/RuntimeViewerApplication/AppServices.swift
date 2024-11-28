import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class AppServices: NSObject {
    
    public static let shared = AppServices()
    
    @Observed
    public var runtimeEngine: RuntimeEngine = .shared
    
}


public class RuntimeListingsManager {
    public static let shared = RuntimeListingsManager()
    
    public private(set) var systemListings: [RuntimeEngine] = []
    
    public private(set) var attachedListings: [RuntimeEngine] = []
    
}

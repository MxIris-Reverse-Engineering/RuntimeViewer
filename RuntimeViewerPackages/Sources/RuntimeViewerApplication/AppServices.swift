import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class AppServices: NSObject {
    
    public static let shared = AppServices()
    
    @Observed
    public var runtimeListings: RuntimeListings = .shared
    
}

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class AppServices: NSObject {
    @Observed
    public var runtimeListings: RuntimeListings = .shared
    
    @Observed
    public var selectedRuntimeObject: RuntimeObjectType?
}

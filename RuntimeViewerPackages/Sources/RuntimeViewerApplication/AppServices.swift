import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class AppServices {
    public init() {}

    @Observed
    public var runtimeEngine: RuntimeEngine = .shared

    @Observed
    public var selectedRuntimeObject: RuntimeObject?
}

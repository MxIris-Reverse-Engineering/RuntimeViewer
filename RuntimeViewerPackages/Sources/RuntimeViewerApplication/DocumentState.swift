import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class DocumentState {
    public init() {}

    @Observed
    public var runtimeEngine: RuntimeEngine = .local

    @Observed
    public var selectedRuntimeObject: RuntimeObject?

    @Observed
    public var currentImageName: String?

    @Observed
    public var currentImagePath: String?

    @Observed
    public var currentSubtitle: String = ""
}

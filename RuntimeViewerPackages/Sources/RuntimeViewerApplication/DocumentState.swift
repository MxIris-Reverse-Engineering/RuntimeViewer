import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures

@MainActor
public final class DocumentState {
    public init() {}

    @Observed
    public var runtimeEngine: RuntimeEngine = .local

    @Observed
    public var selectedRuntimeObject: RuntimeObject?

    @Observed
    public var currentImageNode: RuntimeImageNode?

    @Observed
    public var currentSubtitle: String = ""
}

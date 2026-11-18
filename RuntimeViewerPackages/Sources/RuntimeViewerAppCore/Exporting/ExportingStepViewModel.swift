#if os(macOS)

import RuntimeViewerArchitectures

/// What the export sheet's frame shows around each step: the step's title and the titles and
/// states of its Previous and Next buttons.
public protocol ExportingStepViewModel: ViewModelProtocol {
    var title: Driver<String> { get }
    var previousTitle: Driver<String> { get }
    var nextTitle: Driver<String> { get }
    var isNextEnabled: Driver<Bool> { get }
    var isPreviousEnabled: Driver<Bool> { get }
}

extension ExportingStepViewModel {
    public var previousTitle: Driver<String> {
        "Previous"
    }

    public var nextTitle: Driver<String> {
        "Next"
    }
}

#endif

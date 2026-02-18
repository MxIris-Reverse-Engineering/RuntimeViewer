import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import OrderedCollections

typealias ExportFormat = RuntimeInterfaceExportConfiguration.Format

enum ExportingStep: Int {
    case configuration
    case progress
    case completion
}

@MainActor
final class ExportingState {
    let imagePath: String

    let imageName: String

    @Observed
    var allObjects: [RuntimeObject] = []

    @Observed
    var objcFormat: ExportFormat = .directory

    @Observed
    var swiftFormat: ExportFormat = .singleFile

    @Observed
    var destinationURL: URL?

    @Observed
    var exportResult: RuntimeInterfaceExportResult?

    @Observed
    var currentStep: ExportingStep = .configuration

    init(imagePath: String, imageName: String) {
        self.imagePath = imagePath
        self.imageName = imageName
    }
    
    static let completionStepTesting = ExportingState(imagePath: "/System/Library/Frameworks/AppKit.framework/AppKit", imageName: "AppKit").then {
        $0.exportResult = .init(succeeded: 300, failed: 0, totalDuration: 5.0, objcCount: 100, swiftCount: 200)
    }
}

extension ExportingState: Then {}

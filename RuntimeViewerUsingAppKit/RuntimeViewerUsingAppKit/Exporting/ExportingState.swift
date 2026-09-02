import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import OrderedCollections

typealias ExportFormat = RuntimeInterfaceExportConfiguration.Format

enum ExportingDefaultsKey {
    static let objcFormat = "Exporting.objcFormat"
    static let swiftFormat = "Exporting.swiftFormat"
    static let includeMetadata = "Exporting.includeMetadata"
}

enum ExportingStep: Int {
    case configuration
    case progress
    case completion
}

@MainActor
final class ExportingState {
    let imagePath: String

    let imageName: String

    @RxObserved
    var allObjects: [RuntimeObject] = []

    @RxObserved
    var objcFormat: ExportFormat = .directory

    @RxObserved
    var swiftFormat: ExportFormat = .singleFile

    @RxObserved
    var includeMetadata: Bool = true

    @RxObserved
    var destinationURL: URL?

    @RxObserved
    var exportResult: RuntimeInterfaceExportResult?

    @RxObserved
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

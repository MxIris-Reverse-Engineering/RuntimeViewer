#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public typealias ExportFormat = RuntimeInterfaceExportConfiguration.Format

public enum ExportingDefaultsKey {
    public static let objcFormat = "Exporting.objcFormat"
    public static let swiftFormat = "Exporting.swiftFormat"
    public static let includeMetadata = "Exporting.includeMetadata"
}

public enum ExportingStep: Int {
    case configuration
    case progress
    case completion
}

@MainActor
public final class ExportingState {
    public let imagePath: String

    public let imageName: String

    @RxObserved
    public var allObjects: [RuntimeObject] = []

    @RxObserved
    public var objcFormat: ExportFormat = .directory

    @RxObserved
    public var swiftFormat: ExportFormat = .singleFile

    @RxObserved
    public var includeMetadata: Bool = true

    @RxObserved
    public var destinationURL: URL?

    @RxObserved
    public var exportResult: RuntimeInterfaceExportResult?

    @RxObserved
    public var currentStep: ExportingStep = .configuration

    public init(imagePath: String, imageName: String) {
        self.imagePath = imagePath
        self.imageName = imageName
    }

    public static let completionStepTesting = ExportingState(imagePath: "/System/Library/Frameworks/AppKit.framework/AppKit", imageName: "AppKit").then {
        $0.exportResult = .init(succeeded: 300, failed: 0, totalDuration: 5.0, objcCount: 100, swiftCount: 200)
    }
}

extension ExportingState: Then {}

#endif

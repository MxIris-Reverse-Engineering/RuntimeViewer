#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum BatchExportingStep: Int {
    case imageSelection = 0
    case configuration = 1
    case progress = 2
    case completion = 3
}

public struct BatchExportingImage: Hashable, Sendable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// A single object whose interface failed to export, kept so the per-image row
/// can surface *which* objects failed and *why* instead of only a failure count.
public struct BatchExportingObjectFailure: Sendable, Hashable {
    public let objectName: String
    public let errorDescription: String

    public init(objectName: String, errorDescription: String) {
        self.objectName = objectName
        self.errorDescription = errorDescription
    }
}

extension Collection where Element == BatchExportingObjectFailure {
    /// Multi-line tooltip listing each failed object and its reason, or `nil`
    /// when nothing failed. Capped so a pathological image doesn't build a
    /// thousand-line tooltip.
    public var exportFailureTooltip: String? {
        guard !isEmpty else { return nil }
        let total = count
        let header = total == 1 ? "1 interface failed:" : "\(total) interfaces failed:"
        var lines = [header] + prefix(50).map { "• \($0.objectName) — \($0.errorDescription)" }
        if total > 50 {
            lines.append("…and \(total - 50) more")
        }
        return lines.joined(separator: "\n")
    }
}

public struct BatchExportingPerImageOutcome: Sendable {
    public let image: BatchExportingImage
    public let outcome: Outcome
    /// Per-object interface failures collected from the export reporter. Empty
    /// when the whole image failed up front (that error lives in `.failure`),
    /// or when every object exported cleanly.
    public let objectFailures: [BatchExportingObjectFailure]

    public init(image: BatchExportingImage, outcome: Outcome, objectFailures: [BatchExportingObjectFailure] = []) {
        self.image = image
        self.outcome = outcome
        self.objectFailures = objectFailures
    }

    public enum Outcome: Sendable {
        case success(RuntimeInterfaceExportResult)
        case failure(errorDescription: String)
    }

    public var succeeded: Int {
        if case .success(let result) = outcome { return result.succeeded }
        return 0
    }

    public var failed: Int {
        if case .success(let result) = outcome { return result.failed }
        return 0
    }

    public var totalDuration: TimeInterval {
        if case .success(let result) = outcome { return result.totalDuration }
        return 0
    }

    public var objcCount: Int {
        if case .success(let result) = outcome { return result.objcCount }
        return 0
    }

    public var swiftCount: Int {
        if case .success(let result) = outcome { return result.swiftCount }
        return 0
    }

    public var cPlusPlusCount: Int {
        if case .success(let result) = outcome { return result.cPlusPlusCount }
        return 0
    }

    public var didSucceed: Bool {
        if case .success = outcome { return true }
        return false
    }
}

public struct BatchExportingAggregatedResult: Sendable {
    public let imagesSucceeded: Int
    public let imagesFailed: Int
    public let interfacesSucceeded: Int
    public let interfacesFailed: Int
    public let totalDuration: TimeInterval
    public let totalObjcCount: Int
    public let totalSwiftCount: Int
    public let totalCPlusPlusCount: Int

    public init(outcomes: [BatchExportingPerImageOutcome]) {
        var imagesSucceeded = 0
        var imagesFailed = 0
        var interfacesSucceeded = 0
        var interfacesFailed = 0
        var totalDuration: TimeInterval = 0
        var totalObjcCount = 0
        var totalSwiftCount = 0
        var totalCPlusPlusCount = 0
        for outcome in outcomes {
            if outcome.didSucceed {
                imagesSucceeded += 1
            } else {
                imagesFailed += 1
            }
            interfacesSucceeded += outcome.succeeded
            interfacesFailed += outcome.failed
            totalDuration += outcome.totalDuration
            totalObjcCount += outcome.objcCount
            totalSwiftCount += outcome.swiftCount
            totalCPlusPlusCount += outcome.cPlusPlusCount
        }
        self.imagesSucceeded = imagesSucceeded
        self.imagesFailed = imagesFailed
        self.interfacesSucceeded = interfacesSucceeded
        self.interfacesFailed = interfacesFailed
        self.totalDuration = totalDuration
        self.totalObjcCount = totalObjcCount
        self.totalSwiftCount = totalSwiftCount
        self.totalCPlusPlusCount = totalCPlusPlusCount
    }
}

@MainActor
public final class BatchExportingState {
    @RxObserved
    public var availableImages: [BatchExportingImage] = []

    /// The tree the image selection step shows; `nil` until the coordinator has built it.
    @RxObserved
    public var imageTree: BatchExportingImageTree?

    @RxObserved
    public var selectedImagePaths: Set<String> = []

    @RxObserved
    public var objcFormat: ExportFormat = .directory

    @RxObserved
    public var swiftFormat: ExportFormat = .singleFile

    @RxObserved
    public var cPlusPlusFormat: ExportFormat = .directory

    @RxObserved
    public var includeMetadata: Bool = true

    @RxObserved
    public var destinationURL: URL?

    @RxObserved
    public var progressRowViewModels: [BatchExportingProgressRowViewModel] = []

    @RxObserved
    public var perImageOutcomes: [BatchExportingPerImageOutcome] = []

    @RxObserved
    public var aggregatedResult: BatchExportingAggregatedResult?

    @RxObserved
    public var currentStep: BatchExportingStep = .imageSelection

    public init() {}

    public var selectedImages: [BatchExportingImage] {
        availableImages.filter { selectedImagePaths.contains($0.path) }
    }
}

#endif

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

enum BatchExportingStep: Int {
    case imageSelection = 0
    case configuration = 1
    case progress = 2
    case completion = 3
}

struct BatchExportingImage: Hashable, Sendable {
    let path: String
    let name: String
    let group: String
}

/// A single object whose interface failed to export, kept so the per-image row
/// can surface *which* objects failed and *why* instead of only a failure count.
struct BatchExportingObjectFailure: Sendable, Hashable {
    let objectName: String
    let errorDescription: String
}

extension Collection where Element == BatchExportingObjectFailure {
    /// Multi-line tooltip listing each failed object and its reason, or `nil`
    /// when nothing failed. Capped so a pathological image doesn't build a
    /// thousand-line tooltip.
    var exportFailureTooltip: String? {
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

struct BatchExportingPerImageOutcome: Sendable {
    let image: BatchExportingImage
    let outcome: Outcome
    /// Per-object interface failures collected from the export reporter. Empty
    /// when the whole image failed up front (that error lives in `.failure`),
    /// or when every object exported cleanly.
    let objectFailures: [BatchExportingObjectFailure]

    init(image: BatchExportingImage, outcome: Outcome, objectFailures: [BatchExportingObjectFailure] = []) {
        self.image = image
        self.outcome = outcome
        self.objectFailures = objectFailures
    }

    enum Outcome: Sendable {
        case success(RuntimeInterfaceExportResult)
        case failure(errorDescription: String)
    }

    var succeeded: Int {
        if case .success(let result) = outcome { return result.succeeded }
        return 0
    }

    var failed: Int {
        if case .success(let result) = outcome { return result.failed }
        return 0
    }

    var totalDuration: TimeInterval {
        if case .success(let result) = outcome { return result.totalDuration }
        return 0
    }

    var objcCount: Int {
        if case .success(let result) = outcome { return result.objcCount }
        return 0
    }

    var swiftCount: Int {
        if case .success(let result) = outcome { return result.swiftCount }
        return 0
    }

    var didSucceed: Bool {
        if case .success = outcome { return true }
        return false
    }
}

struct BatchExportingAggregatedResult: Sendable {
    let imagesSucceeded: Int
    let imagesFailed: Int
    let interfacesSucceeded: Int
    let interfacesFailed: Int
    let totalDuration: TimeInterval
    let totalObjcCount: Int
    let totalSwiftCount: Int

    init(outcomes: [BatchExportingPerImageOutcome]) {
        var imagesSucceeded = 0
        var imagesFailed = 0
        var interfacesSucceeded = 0
        var interfacesFailed = 0
        var totalDuration: TimeInterval = 0
        var totalObjcCount = 0
        var totalSwiftCount = 0
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
        }
        self.imagesSucceeded = imagesSucceeded
        self.imagesFailed = imagesFailed
        self.interfacesSucceeded = interfacesSucceeded
        self.interfacesFailed = interfacesFailed
        self.totalDuration = totalDuration
        self.totalObjcCount = totalObjcCount
        self.totalSwiftCount = totalSwiftCount
    }
}

@MainActor
final class BatchExportingState {
    @Observed
    var availableImages: [BatchExportingImage] = []

    @Observed
    var selectedImagePaths: Set<String> = []

    @Observed
    var searchString: String = ""

    @Observed
    var objcFormat: ExportFormat = .directory

    @Observed
    var swiftFormat: ExportFormat = .singleFile

    @Observed
    var includeMetadata: Bool = true

    @Observed
    var destinationURL: URL?

    @Observed
    var progressRowViewModels: [BatchExportingProgressRowViewModel] = []

    @Observed
    var perImageOutcomes: [BatchExportingPerImageOutcome] = []

    @Observed
    var aggregatedResult: BatchExportingAggregatedResult?

    @Observed
    var currentStep: BatchExportingStep = .imageSelection

    var selectedImages: [BatchExportingImage] {
        availableImages.filter { selectedImagePaths.contains($0.path) }
    }
}

import Foundation

public struct RuntimeObjectsLoadingProgress: Sendable, Codable {
    public enum Phase: String, Sendable, Codable {
        case preparingObjCSection
        case loadingObjCClasses
        case loadingObjCProtocols
        case loadingObjCCategories
        case extractingSwiftTypes
        case extractingSwiftProtocols
        case extractingSwiftConformances
        case extractingSwiftAssociatedTypes
        case indexingSwiftTypes
        case indexingSwiftProtocols
        case indexingSwiftConformances
        case indexingSwiftExtensions
        case buildingObjects
    }

    public let phase: Phase
    public let itemDescription: String
    public let currentCount: Int
    public let totalCount: Int

    public init(phase: Phase, itemDescription: String, currentCount: Int, totalCount: Int) {
        self.phase = phase
        self.itemDescription = itemDescription
        self.currentCount = currentCount
        self.totalCount = totalCount
    }
}

public enum RuntimeObjectsLoadingEvent: Sendable {
    case progress(RuntimeObjectsLoadingProgress)
    case completed([RuntimeObject])
}

// MARK: - Phase Display

extension RuntimeObjectsLoadingProgress.Phase {
    public var displayDescription: String {
        switch self {
        case .preparingObjCSection: return "Preparing Objective-C section..."
        case .loadingObjCClasses: return "Loading Objective-C classes..."
        case .loadingObjCProtocols: return "Loading Objective-C protocols..."
        case .loadingObjCCategories: return "Loading Objective-C categories..."
        case .extractingSwiftTypes: return "Extracting Swift types..."
        case .extractingSwiftProtocols: return "Extracting Swift protocols..."
        case .extractingSwiftConformances: return "Extracting Swift conformances..."
        case .extractingSwiftAssociatedTypes: return "Extracting Swift associated types..."
        case .indexingSwiftTypes: return "Indexing Swift types..."
        case .indexingSwiftProtocols: return "Indexing Swift protocols..."
        case .indexingSwiftConformances: return "Indexing Swift conformances..."
        case .indexingSwiftExtensions: return "Indexing Swift extensions..."
        case .buildingObjects: return "Building objects..."
        }
    }

    public var progressRange: (start: Double, end: Double) {
        switch self {
        case .preparingObjCSection:          return (0.00, 0.02)
        case .loadingObjCClasses:            return (0.02, 0.25)
        case .loadingObjCProtocols:          return (0.25, 0.35)
        case .loadingObjCCategories:         return (0.35, 0.45)
        case .extractingSwiftTypes:          return (0.45, 0.48)
        case .extractingSwiftProtocols:      return (0.48, 0.50)
        case .extractingSwiftConformances:   return (0.50, 0.52)
        case .extractingSwiftAssociatedTypes: return (0.52, 0.55)
        case .indexingSwiftTypes:            return (0.55, 0.72)
        case .indexingSwiftProtocols:        return (0.72, 0.80)
        case .indexingSwiftConformances:     return (0.80, 0.87)
        case .indexingSwiftExtensions:       return (0.87, 0.90)
        case .buildingObjects:              return (0.90, 1.00)
        }
    }
}

extension RuntimeObjectsLoadingProgress {
    public var overallFraction: Double {
        let range = phase.progressRange
        let phaseWidth = range.end - range.start
        if totalCount > 0 {
            let itemFraction = Double(currentCount) / Double(totalCount)
            return range.start + phaseWidth * itemFraction
        } else {
            return range.start
        }
    }
}

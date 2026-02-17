import Foundation
import RuntimeViewerCore

enum ExportFormat: Int {
    case singleFile = 0
    case directory = 1
}

final class ExportingState {
    let imagePath: String
    let imageName: String

    var allObjects: [RuntimeObject] = []
    var selectedObjects: Set<RuntimeObject> = []

    var objcFormat: ExportFormat = .singleFile
    var swiftFormat: ExportFormat = .singleFile

    var destinationURL: URL?

    var objcObjects: [RuntimeObject] {
        allObjects.filter { if case .swift = $0.kind { return false } else { return true } }
    }

    var swiftObjects: [RuntimeObject] {
        allObjects.filter { if case .swift = $0.kind { return true } else { return false } }
    }

    var selectedObjcObjects: [RuntimeObject] {
        objcObjects.filter { selectedObjects.contains($0) }
    }

    var selectedSwiftObjects: [RuntimeObject] {
        swiftObjects.filter { selectedObjects.contains($0) }
    }

    init(imagePath: String, imageName: String) {
        self.imagePath = imagePath
        self.imageName = imageName
    }
}

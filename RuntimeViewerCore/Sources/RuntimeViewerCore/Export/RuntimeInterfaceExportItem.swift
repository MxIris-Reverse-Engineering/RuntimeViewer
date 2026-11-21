import Foundation

struct RuntimeInterfaceExportItem: Sendable {
    /// The interfaces written together: into one file in the single-file
    /// format, into one directory in the directory format.
    enum Group: CaseIterable, Sendable {
        /// Objective-C headers, C types included.
        case objectiveC
        case swift
        case cPlusPlus

        /// The directory the directory format writes the group's files into.
        var directoryName: String {
            switch self {
            case .objectiveC: "ObjCHeaders"
            case .swift: "SwiftInterfaces"
            case .cPlusPlus: "CPlusPlusHeaders"
            }
        }

        /// The extension of the one file the single-file format writes.
        var singleFileExtension: String {
            switch self {
            case .objectiveC: "h"
            case .swift: "swiftinterface"
            case .cPlusPlus: "hpp"
            }
        }
    }

    let object: RuntimeObject
    let plainText: String
    let suggestedFileName: String

    var group: Group {
        switch object.kind {
        case .objc, .c: .objectiveC
        case .swift: .swift
        case .cPlusPlus: .cPlusPlus
        }
    }
}

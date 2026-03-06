import Foundation

enum RuntimeInterfaceExportWriter {
    static func writeSingleFile(
        items: [RuntimeInterfaceExportItem],
        to directory: URL,
        imageName: String
    ) throws {
        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let combined = objcItems.map(\.plainText).joined(separator: "\n\n")
            let file = directory.appendingPathComponent("\(imageName).h")
            try combined.write(to: file, atomically: true, encoding: .utf8)
        }

        if !swiftItems.isEmpty {
            let combined = swiftItems.map(\.plainText).joined(separator: "\n\n")
            let file = directory.appendingPathComponent("\(imageName).swiftinterface")
            try combined.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static func writeDirectory(
        items: [RuntimeInterfaceExportItem],
        to directory: URL
    ) throws {
        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let objcDir = directory.appendingPathComponent("ObjCHeaders")
            try FileManager.default.createDirectory(at: objcDir, withIntermediateDirectories: true)
            for item in objcItems {
                let file = objcDir.appendingPathComponent(item.suggestedFileName)
                try item.plainText.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        if !swiftItems.isEmpty {
            let swiftDir = directory.appendingPathComponent("SwiftInterfaces")
            try FileManager.default.createDirectory(at: swiftDir, withIntermediateDirectories: true)
            for item in swiftItems {
                let file = swiftDir.appendingPathComponent(item.suggestedFileName)
                try item.plainText.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    static func writeIMPMappings(
        _ mappings: [RuntimeIMPMapping],
        to directory: URL,
        imageName: String
    ) throws {
        guard !mappings.isEmpty else { return }
        let sorted = mappings.sorted { $0.address < $1.address }
        var lines = [
            "# RuntimeViewer IDA IMP Mapping",
            "# Image: \(imageName)",
        ]
        for mapping in sorted {
            lines.append("\(mapping.address) \(mapping.selector)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        let file = directory.appendingPathComponent("\(imageName).ida_map")
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
}

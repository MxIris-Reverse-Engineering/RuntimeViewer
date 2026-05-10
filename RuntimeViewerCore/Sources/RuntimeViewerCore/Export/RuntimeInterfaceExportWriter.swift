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

    struct WriteResult {
        var writtenCount: Int = 0
        var failedItems: [(item: RuntimeInterfaceExportItem, error: any Error)] = []
    }

    static func writeDirectory(
        items: [RuntimeInterfaceExportItem],
        to directory: URL
    ) throws -> WriteResult {
        var result = WriteResult()
        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let objcDir = directory.appendingPathComponent("ObjCHeaders")
            try FileManager.default.createDirectory(at: objcDir, withIntermediateDirectories: true)
            for item in objcItems {
                do {
                    let file = objcDir.appendingPathComponent(item.suggestedFileName)
                    try item.plainText.write(to: file, atomically: true, encoding: .utf8)
                    result.writtenCount += 1
                } catch {
                    result.failedItems.append((item: item, error: error))
                }
            }
        }

        if !swiftItems.isEmpty {
            let swiftDir = directory.appendingPathComponent("SwiftInterfaces")
            try FileManager.default.createDirectory(at: swiftDir, withIntermediateDirectories: true)
            for item in swiftItems {
                do {
                    let file = swiftDir.appendingPathComponent(item.suggestedFileName)
                    try item.plainText.write(to: file, atomically: true, encoding: .utf8)
                    result.writtenCount += 1
                } catch {
                    result.failedItems.append((item: item, error: error))
                }
            }
        }

        return result
    }

    static func writeMetadata(
        _ metadata: RuntimeInterfaceExportMetadata,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let readmeURL = directory.appendingPathComponent("README.md")
        try metadata.makeREADME().write(to: readmeURL, atomically: true, encoding: .utf8)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let plistData = try encoder.encode(metadata)
        let plistURL = directory.appendingPathComponent("RuntimeViewerExportInfo.plist")
        try plistData.write(to: plistURL, options: .atomic)
    }
}

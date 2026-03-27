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
}

import Foundation

enum RuntimeInterfaceExportWriter {
    struct WriteResult {
        var writtenCount: Int = 0
        var failedItems: [(item: RuntimeInterfaceExportItem, error: any Error)] = []
    }

    /// Writes the interfaces of one group: all of them into
    /// `<imageName>.<extension>` in the single-file format, each into a file
    /// of its own under the group's directory in the directory format.
    /// `items` are the group's, in the order they are written.
    static func write(
        _ items: [RuntimeInterfaceExportItem],
        as group: RuntimeInterfaceExportItem.Group,
        format: RuntimeInterfaceExportConfiguration.Format,
        to directory: URL,
        imageName: String
    ) throws -> WriteResult {
        switch format {
        case .singleFile:
            let combined = items.map(\.plainText).joined(separator: "\n\n")
            let file = directory.appendingPathComponent("\(imageName).\(group.singleFileExtension)")
            try combined.write(to: file, atomically: true, encoding: .utf8)
            return WriteResult(writtenCount: items.count)
        case .directory:
            var result = WriteResult()
            let groupDirectory = directory.appendingPathComponent(group.directoryName)
            try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
            for item in items {
                do {
                    let file = groupDirectory.appendingPathComponent(item.suggestedFileName)
                    try item.plainText.write(to: file, atomically: true, encoding: .utf8)
                    result.writtenCount += 1
                } catch {
                    result.failedItems.append((item: item, error: error))
                }
            }
            return result
        }
    }

    static func writeMetadata(
        _ metadata: RuntimeInterfaceExportMetadata,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let readmeURL = directory.appendingPathComponent("README.md")
        try metadata.makeREADME().write(to: readmeURL, atomically: true, encoding: .utf8)
    }
}

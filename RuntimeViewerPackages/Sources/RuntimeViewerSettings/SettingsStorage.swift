import Foundation

protocol SettingsStorageStrategy {
    func save(_ data: Data) async throws
    func load() async throws -> Data
}

struct SettingsFileSystemStorage: SettingsStorageStrategy {
    let fileName: String
    let directory: FileManager.SearchPathDirectory

    init(fileName: String = "settings.json", directory: FileManager.SearchPathDirectory = .applicationSupportDirectory) {
        self.fileName = fileName
        self.directory = directory
    }

    private var fileURL: URL {
        let paths = FileManager.default.urls(for: directory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("MyAppConfig")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func save(_ data: Data) async throws {
        try data.write(to: fileURL, options: [.atomic])
    }

    func load() async throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SettingsStorageError.noData
        }
        return try Data(contentsOf: fileURL)
    }
}

enum SettingsStorageError: Error {
    case noData
    case encodingFailed
    case decodingFailed
}

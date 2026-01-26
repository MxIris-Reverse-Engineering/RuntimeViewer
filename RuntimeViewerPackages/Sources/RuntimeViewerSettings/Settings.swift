import Foundation
import FoundationToolbox
import Observation
import Dependencies
import RuntimeViewerCore

@Observable
public final class Settings: Codable, Loggable {
    public static let shared = Settings()

    private static var storage: SettingsStorageStrategy = SettingsFileSystemStorage()

    public var general: General = .init() {
        didSet { scheduleAutoSave() }
    }

    public var notifications: Notifications = .init() {
        didSet { scheduleAutoSave() }
    }

    public var transformer: Transformer = .init() {
        didSet { scheduleAutoSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Error>?

    fileprivate init() {
        Task {
            await load()
        }
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.general = try container.decodeIfPresent(General.self, forKey: .general) ?? .init()
        self.notifications = try container.decodeIfPresent(Notifications.self, forKey: .notifications) ?? .init()
        self.transformer = try container.decodeIfPresent(Transformer.self, forKey: .transformer) ?? .init()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(general, forKey: .general)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(transformer, forKey: .transformer)
    }

    private enum CodingKeys: String, CodingKey {
        case general
        case notifications
        case transformer
    }

    private func scheduleAutoSave() {
        saveTask?.cancel()

        saveTask = Task {
            try await Task.sleep(for: .seconds(1))

            await saveNow()
        }
    }

    private func saveNow() async {
        do {
            let data = try JSONEncoder().encode(self)
            try await Self.storage.save(data)
            logger.debug("Settings auto-saved successfully.")
        } catch {
            logger.debug("Failed to save settings: \(error, privacy: .public)")
        }
    }

    private func load() async {
        do {
            let data = try await Self.storage.load()
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            general = decoded.general
            logger.debug("Settings loaded successfully.")
        } catch {
            logger.debug("No saved settings found or load failed, using defaults. (\(error, privacy: .public))")
        }
    }
}

extension Settings {
    /// The appearance of the app
    /// - **system**: uses the system appearance
    /// - **dark**: always uses dark appearance
    /// - **light**: always uses light appearance
    public enum Appearances: String, Codable {
        case system
        case light
        case dark
    }

    public struct General: Codable {
        public var appearance: Appearances = .system
    }

    public struct Notifications: Codable {
        /// Whether notifications are enabled globally
        public var isEnabled: Bool = true

        /// Whether to show notification when connected to a runtime engine
        public var showOnConnect: Bool = true

        /// Whether to show notification when disconnected from a runtime engine
        public var showOnDisconnect: Bool = true
    }

    public struct Transformer: Codable {
        /// Whether interface transformers are enabled
        public var isEnabled: Bool = false

        /// Whether to use predefined stdint.h type replacements
        public var useStdintReplacements: Bool = false

        /// Custom type replacement rules
        public var customReplacements: [CTypeReplacement] = []

        public init(
            isEnabled: Bool = false,
            useStdintReplacements: Bool = false,
            customReplacements: [CTypeReplacement] = []
        ) {
            self.isEnabled = isEnabled
            self.useStdintReplacements = useStdintReplacements
            self.customReplacements = customReplacements
        }

        /// Converts to TransformerConfiguration for use with RuntimeEngine
        public func toConfiguration() -> TransformerConfiguration {
            TransformerConfiguration(
                isEnabled: isEnabled,
                customTypeReplacements: customReplacements,
                useStdintReplacements: useStdintReplacements
            )
        }
    }
}

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

    func save(_ data: Data) throws {
        try data.write(to: fileURL, options: [.atomic])
    }

    func load() throws -> Data {
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


private enum SettingsKey: DependencyKey {
    static let liveValue = Settings.shared
    static let previewValue = Settings()
}

extension DependencyValues {
    public var settings: Settings {
        get { self[SettingsKey.self] }
        set { self[SettingsKey.self] = newValue }
    }
}

import Foundation
import FoundationToolbox
import Observation
import MetaCodable

@Observable
@Codable
@Loggable
public final class Settings {
    public static let shared = Settings()

    private static var storage: SettingsStorageStrategy = SettingsFileSystemStorage()

    @Default(ifMissing: General())
    public var general: General = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(ifMissing: Notifications())
    public var notifications: Notifications = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(ifMissing: TransformerSettings())
    public var transformer: TransformerSettings = .init() {
        didSet { scheduleAutoSave() }
    }

    @IgnoreCoding
    @ObservationIgnored
    private var saveTask: Task<Void, Error>?

    internal init() {
        Task {
            await load()
        }
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
            #log(.debug, "Settings auto-saved successfully.")
        } catch {
            #log(.debug, "Failed to save settings: \(error, privacy: .public)")
        }
    }

    private func load() async {
        do {
            let data = try await Self.storage.load()
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            general = decoded.general
            notifications = decoded.notifications
            transformer = decoded.transformer
            #log(.debug, "Settings loaded successfully.")
        } catch {
            #log(.debug, "No saved settings found or load failed, using defaults. (\(error, privacy: .public))")
        }
    }
}

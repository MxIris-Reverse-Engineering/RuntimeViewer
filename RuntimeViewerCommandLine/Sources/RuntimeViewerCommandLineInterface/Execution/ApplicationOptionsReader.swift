import Foundation
import RuntimeViewerCore

/// Reads the generation options the RuntimeViewer app has persisted, for
/// `--options app`.
///
/// `async` so the app, when it is the host, can answer from its live settings
/// on the main actor; the file-based reader below answers synchronously.
public protocol ApplicationOptionsReading: Sendable {
    func readGenerationOptions() async -> RuntimeObjectInterface.GenerationOptions
}

/// Reads the app's files the way the app writes them, without linking the app.
///
/// - The generation options live in the app's `UserDefaults` domain under the
///   key `generationOptions`, JSON-encoded (`RxDefaultsPlus.UserDefault`).
/// - The transformer configuration lives in
///   `~/Library/Application Support/RuntimeViewer[-Debug]/settings.json` under
///   the top-level key `transformer` (`RuntimeViewerSettings.Settings`).
///
/// A missing or unreadable file yields the defaults for that half; the two are
/// independent. A Debug tool reads the Debug app's files.
public struct ApplicationOptionsReader: ApplicationOptionsReading {
    /// Domains tried in order; the first one holding options wins.
    public let bundleIdentifiers: [String]
    public let settingsFileURL: URL?

    public init(bundleIdentifiers: [String], settingsFileURL: URL?) {
        self.bundleIdentifiers = bundleIdentifiers
        self.settingsFileURL = settingsFileURL
    }

    public init() {
        self.init(
            bundleIdentifiers: Self.defaultBundleIdentifiers,
            settingsFileURL: Self.defaultSettingsFileURL
        )
    }

    /// The same identifiers the host locates the app bundle by.
    public static var defaultBundleIdentifiers: [String] { ApplicationBundleLocator.defaultBundleIdentifiers }

    public static var defaultSettingsFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(CommandLineHostPaths.applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func readGenerationOptions() -> RuntimeObjectInterface.GenerationOptions {
        var options = readPersistedOptions() ?? RuntimeObjectInterface.GenerationOptions()
        if let settingsDerived = readSettingsFile() {
            options.transformer = settingsDerived.transformer
        }
        return options
    }

    private func readPersistedOptions() -> RuntimeObjectInterface.GenerationOptions? {
        for bundleIdentifier in bundleIdentifiers {
            guard let defaults = UserDefaults(suiteName: bundleIdentifier),
                  let data = defaults.data(forKey: "generationOptions") else { continue }
            if let options = try? JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: data) {
                return options
            }
        }
        return nil
    }

    /// Decodes `settings.json` as a `GenerationOptions`: only the `transformer`
    /// key overlaps, every other key is ignored, and the missing option groups
    /// take their defaults. That spares this module from naming the settings
    /// schema or the transformer type.
    private func readSettingsFile() -> RuntimeObjectInterface.GenerationOptions? {
        guard let settingsFileURL, let data = try? Data(contentsOf: settingsFileURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: data)
    }
}

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
/// - The global Generation Options live in
///   `~/Library/Application Support/RuntimeViewer[-Debug]/settings.json` under
///   `generationOptions.global` (`RuntimeViewerSettings.Settings`; proposal
///   `generation-options-image-overrides`). An app from before kept them in its
///   `UserDefaults` domain under the key `generationOptions`, JSON-encoded
///   (`RxDefaultsPlus.UserDefault`), which is read when the settings file has
///   none. What the app overrides for one image is not read: `--options app`
///   is the global options.
/// - The transformer configuration lives in the same `settings.json` under the
///   top-level key `transformer`.
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
        var options = readSettingsFileGlobalOptions() ?? readPersistedOptions() ?? RuntimeObjectInterface.GenerationOptions()
        if let settingsDerived = readSettingsFile() {
            options.transformer = settingsDerived.transformer
        }
        return options
    }

    /// The global Generation Options in `settings.json`; `nil` when the file
    /// has none — an app from before they moved there — or cannot be read.
    private func readSettingsFileGlobalOptions() -> RuntimeObjectInterface.GenerationOptions? {
        guard let settingsFileURL, let data = try? Data(contentsOf: settingsFileURL) else { return nil }
        return (try? JSONDecoder().decode(SettingsFileGenerationOptions.self, from: data))?.generationOptions?.global
    }

    /// The one branch of `settings.json` this reads the options from, so this
    /// module never names the settings schema.
    private struct SettingsFileGenerationOptions: Decodable {
        struct Branch: Decodable {
            let global: RuntimeObjectInterface.GenerationOptions?
        }

        let generationOptions: Branch?
    }

    /// The options an app from before kept in its user defaults.
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
    /// What `settings.json` yielded. A file that is there but no longer
    /// decodes is not the same as no file at all, and must not pass for one.
    public enum SettingsReadOutcome: Sendable {
        case absent
        case decoded(RuntimeObjectInterface.GenerationOptions)
        case unreadable(String)
    }

    public func readSettings() -> SettingsReadOutcome {
        guard let settingsFileURL, let data = try? Data(contentsOf: settingsFileURL) else { return .absent }
        do {
            return .decoded(try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: data))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    private func readSettingsFile() -> RuntimeObjectInterface.GenerationOptions? {
        switch readSettings() {
        case .decoded(let options):
            return options
        case .unreadable(let reason):
            // Silence here means `--options app` quietly yields library
            // defaults after a settings schema change, and the interfaces stop
            // matching the app's with nothing to say why.
            HostLog.write("Ignoring \(settingsFileURL?.path ?? "the settings file"): it no longer decodes (\(reason))")
            return nil
        case .absent:
            return nil
        }
    }
}

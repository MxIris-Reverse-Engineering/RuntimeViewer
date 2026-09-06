import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommandLineInterface

/// `--options app` reads the app's files the way the app writes them, and
/// degrades to the defaults piecewise when they are missing.
@Suite("Application options reader")
struct ApplicationOptionsReaderTests {
    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "dev.JH.RuntimeViewerCommandLineTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test("Persisted generation options are read from the app's defaults domain")
    func readsPersistedOptions() throws {
        let (suiteName, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persisted = RuntimeObjectInterface.GenerationOptions.mcp
        defaults.set(try JSONEncoder().encode(persisted), forKey: "generationOptions")

        let reader = ApplicationOptionsReader(bundleIdentifiers: [suiteName], settingsFileURL: nil)

        #expect(reader.readGenerationOptions() == persisted)
        #expect(persisted != RuntimeObjectInterface.GenerationOptions(), "the fixture must differ from the defaults for this test to prove anything")
    }

    @Test("The transformer configuration is taken from settings.json")
    func readsTransformerFromSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationOptionsReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let settings = """
            {"mcp":{"isEnabled":false},"transformer":{"objc":{"ivarOffset":{"template":"offset: ${offset}","useHexadecimal":false,"isEnabled":true}}}}
            """
        try Data(settings.utf8).write(to: settingsURL)

        let reader = ApplicationOptionsReader(bundleIdentifiers: [], settingsFileURL: settingsURL)
        let options = reader.readGenerationOptions()

        #expect(options.transformer != RuntimeObjectInterface.GenerationOptions().transformer)
        let encoded = String(decoding: try JSONEncoder().encode(options.transformer), as: UTF8.self)
        #expect(encoded.contains("\"useHexadecimal\":false"))
        // The option groups the file does not carry stay at their defaults.
        #expect(options.objcHeaderOptions == RuntimeObjectInterface.GenerationOptions().objcHeaderOptions)
    }

    @Test("Missing files yield the defaults")
    func missingFilesYieldDefaults() {
        let reader = ApplicationOptionsReader(
            bundleIdentifiers: ["dev.JH.RuntimeViewerCommandLineTests.does-not-exist"],
            settingsFileURL: URL(fileURLWithPath: "/nonexistent/settings.json")
        )
        #expect(reader.readGenerationOptions() == RuntimeObjectInterface.GenerationOptions())
    }

    @Test("Hosts and paths follow the Debug/Release pairing")
    func debugPairing() {
        #if DEBUG
        #expect(CommandLineHostPaths.applicationDirectoryName == "RuntimeViewer-Debug")
        #expect(ApplicationOptionsReader.defaultBundleIdentifiers.contains("dev.JH.RuntimeViewer"))
        #else
        #expect(CommandLineHostPaths.applicationDirectoryName == "RuntimeViewer")
        #expect(ApplicationOptionsReader.defaultBundleIdentifiers == ["com.JH.RuntimeViewer"])
        #endif
        let paths = CommandLineHostPaths.resolveDefault(override: nil, environment: [:])
        #expect(paths.rootDirectory.path.hasSuffix("/Library/Application Support/\(CommandLineHostPaths.applicationDirectoryName)/CommandLineHost"))
        #expect(paths.socketURL.lastPathComponent == "host.sock")

        let overridden = CommandLineHostPaths.resolveDefault(override: "/tmp/x", environment: [CommandLineHostPaths.environmentVariable: "/tmp/y"])
        #expect(overridden.rootDirectory.path == "/tmp/x")
        let fromEnvironment = CommandLineHostPaths.resolveDefault(override: nil, environment: [CommandLineHostPaths.environmentVariable: "/tmp/y"])
        #expect(fromEnvironment.rootDirectory.path == "/tmp/y")
    }

    @Test("The default idle timeout honours its environment variable")
    func idleTimeoutEnvironment() {
        #expect(HostIdleTimeout.resolveDefault(environment: [:]) == 600)
        #expect(HostIdleTimeout.resolveDefault(environment: [HostIdleTimeout.environmentVariable: "30"]) == 30)
        #expect(HostIdleTimeout.resolveDefault(environment: [HostIdleTimeout.environmentVariable: "0"]) == 0)
        #expect(HostIdleTimeout.resolveDefault(environment: [HostIdleTimeout.environmentVariable: "nope"]) == 600)
    }
}

import Testing
import Foundation
@testable import RuntimeViewerCore

@Suite("RuntimeInterfaceExportConfiguration")
struct RuntimeInterfaceExportConfigurationTests {
    @Test("Format raw values")
    func formatRawValues() {
        #expect(RuntimeInterfaceExportConfiguration.Format.singleFile.rawValue == 0)
        #expect(RuntimeInterfaceExportConfiguration.Format.directory.rawValue == 1)
    }

    @Test("init sets all properties")
    func initSetsAllProperties() {
        let directory = URL(fileURLWithPath: "/tmp/export")
        let config = RuntimeInterfaceExportConfiguration(
            imagePath: "/usr/lib/libobjc.A.dylib",
            imageName: "libobjc.A",
            directory: directory,
            objcFormat: .singleFile,
            swiftFormat: .directory,
            generationOptions: .mcp
        )
        #expect(config.imagePath == "/usr/lib/libobjc.A.dylib")
        #expect(config.imageName == "libobjc.A")
        #expect(config.directory == directory)
        #expect(config.objcFormat == .singleFile)
        #expect(config.swiftFormat == .directory)
        #expect(config.includeMetadata == true)
    }

    @Test("init can disable metadata output")
    func initCanDisableMetadataOutput() {
        let config = RuntimeInterfaceExportConfiguration(
            imagePath: "/usr/lib/libobjc.A.dylib",
            imageName: "libobjc.A",
            directory: URL(fileURLWithPath: "/tmp/export"),
            objcFormat: .singleFile,
            swiftFormat: .directory,
            generationOptions: .mcp,
            includeMetadata: false
        )
        #expect(config.includeMetadata == false)
    }
}

@Suite("RuntimeInterfaceExportResult")
struct RuntimeInterfaceExportResultTests {
    @Test("init sets all properties")
    func initSetsAllProperties() {
        let result = RuntimeInterfaceExportResult(
            succeeded: 100,
            failed: 5,
            totalDuration: 12.5,
            objcCount: 60,
            swiftCount: 40
        )
        #expect(result.succeeded == 100)
        #expect(result.failed == 5)
        #expect(result.totalDuration == 12.5)
        #expect(result.objcCount == 60)
        #expect(result.swiftCount == 40)
    }

    @Test("zero counts")
    func zeroCounts() {
        let result = RuntimeInterfaceExportResult(
            succeeded: 0,
            failed: 0,
            totalDuration: 0,
            objcCount: 0,
            swiftCount: 0
        )
        #expect(result.succeeded == 0)
        #expect(result.failed == 0)
    }
}

@Suite("RuntimeInterfaceExportEvent.Phase")
struct RuntimeInterfaceExportPhaseTests {
    @Test("all phases can be created")
    func allPhases() {
        let phases: [RuntimeInterfaceExportEvent.Phase] = [.preparing, .exporting, .writing]
        #expect(phases.count == 3)
    }
}

@Suite("RuntimeInterfaceExportReporter")
struct RuntimeInterfaceExportReporterTests {
    @Test("can be initialized")
    func init_() {
        let reporter = RuntimeInterfaceExportReporter()
        #expect(reporter.events is AsyncStream<RuntimeInterfaceExportEvent>)
    }
}

@Suite("RuntimeInterfaceExportMetadata")
struct RuntimeInterfaceExportMetadataTests {
    @Test("README includes RuntimeViewer, module, date, options, and license metadata")
    func readmeIncludesExportMetadata() {
        let metadata = makeMetadata()
        let readme = metadata.makeREADME()

        #expect(readme.contains("RuntimeViewer 2.0.1 (build 20260510.12.00, commit abc123def456)"))
        #expect(readme.contains("- Path: /usr/lib/libExample.dylib"))
        #expect(readme.contains("- Mach-O current version: 1.2.3"))
        #expect(readme.contains("- Generated at: 1970-01-01T00:00:00.000Z"))
        #expect(readme.contains("## Dump Options"))
        #expect(readme.contains("- Add ivar offset comments: Enabled - Adds ivar memory offset comments"))
        #expect(readme.contains("- Print member addresses: Enabled - Adds member address comments"))
        #expect(readme.contains("- Member sort order: By category - Controls how members are ordered"))
        #expect(readme.contains("- C Type Replacement: Disabled; replacements: none - Rewrites matching C primitive type spellings"))
        #expect(readme.contains("- RuntimeViewer license: MIT License"))
    }

    @Test("make uses engine-provided module metadata")
    func makeUsesEngineProvidedModuleMetadata() {
        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: "/remote/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            imageName: "SwiftUICore",
            directory: FileManager.default.temporaryDirectory,
            objcFormat: .singleFile,
            swiftFormat: .singleFile,
            generationOptions: .mcp
        )
        let module = RuntimeInterfaceExportMetadata.ModuleInfo(
            name: "SwiftUICore",
            path: "/remote/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            resolvedPath: nil,
            bundleIdentifier: "com.apple.SwiftUICore",
            bundleShortVersion: "8.0.66.1.103",
            bundleVersion: "8.0.66.1.103",
            installName: "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            currentVersion: "8.0.66",
            compatibilityVersion: "1.0.0",
            sourceVersion: "1165.1.103",
            uuid: "A8FC6D2D-DFE9-3557-A734-7F2B231F8C97"
        )

        let metadata = RuntimeInterfaceExportMetadata.make(
            configuration: configuration,
            module: module,
            objcInterfaceCount: 1,
            swiftInterfaceCount: 2,
            succeeded: 3,
            failed: 0,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(metadata.module.installName == "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore")
        #expect(metadata.module.currentVersion == "8.0.66")
        #expect(metadata.module.sourceVersion == "1165.1.103")
    }

    @Test("writer emits README only")
    func writerEmitsReadmeOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerExportMetadataTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadata = makeMetadata()
        try RuntimeInterfaceExportWriter.writeMetadata(metadata, to: directory)

        let readmeURL = directory.appendingPathComponent("README.md")
        #expect(FileManager.default.fileExists(atPath: readmeURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("RuntimeViewerExportInfo.plist").path
        ))
    }

    private func makeMetadata() -> RuntimeInterfaceExportMetadata {
        RuntimeInterfaceExportMetadata(
            runtimeViewer: .init(
                name: "RuntimeViewer",
                bundleIdentifier: "dev.mxiris.runtimeviewer",
                version: "2.0.1",
                build: "20260510.12.00",
                gitCommit: "abc123def456",
                gitBranch: "feature/export",
                buildDate: "2026-05-10T12:00:00Z"
            ),
            module: .init(
                name: "libExample",
                path: "/usr/lib/libExample.dylib",
                resolvedPath: nil,
                bundleIdentifier: nil,
                bundleShortVersion: nil,
                bundleVersion: nil,
                installName: "/usr/lib/libExample.dylib",
                currentVersion: "1.2.3",
                compatibilityVersion: "1.0.0",
                sourceVersion: "100.2.3",
                uuid: "4D7909F9-8B04-4C14-8830-CA7BC22FE130"
            ),
            export: .init(
                generatedAt: Date(timeIntervalSince1970: 0),
                objcFormat: "Single file",
                swiftFormat: "Directory",
                objcInterfaceCount: 4,
                swiftInterfaceCount: 6,
                succeeded: 10,
                failed: 1,
                dumpOptions: .describe(.mcp)
            ),
            license: .init(
                runtimeViewerLicense: "MIT License",
                notice: "Generated interfaces are derived from the selected module."
            )
        )
    }
}

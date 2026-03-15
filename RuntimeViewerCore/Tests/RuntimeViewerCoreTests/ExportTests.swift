import Testing
import Foundation
import RuntimeViewerCore

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

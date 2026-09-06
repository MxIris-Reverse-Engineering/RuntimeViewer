import ArgumentParser
import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// The real client code path against an in-process host that serves a real
/// local engine: what `runtime-viewer-cli <command> --json` prints.
@Suite("End to end against the local runtime", .serialized, .timeLimit(.minutes(2)))
struct EndToEndTests {
    /// Options go through the real parser: a `ParsableArguments` value built
    /// with `init()` traps on first read, its properties being definitions
    /// rather than values until parsed.
    private func makeRunner(paths: CommandLineHostPaths, json: Bool = true) throws -> (CommandRunner, CapturedOutput) {
        var arguments = ["--host-directory", paths.rootDirectory.path, "--no-spawn"]
        if json {
            arguments.append("--json")
        }
        let options = try GlobalOptions.parse(arguments)
        let (streams, captured) = OutputStreams.capturing()
        return (CommandRunner(globalOptions: options, output: streams, launcher: nil), captured)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("interface NSObject --image /usr/lib/libobjc.A.dylib prints the class interface")
    func interfaceOfNSObject() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths)

        try await runner.run(.interface(InterfaceCommand(image: TestLocalEngine.libobjcPath, typeName: "NSObject")))

        let document = try jsonObject(captured.standardOutput)
        let interfaceText = try #require(document["interfaceText"] as? String)
        #expect(interfaceText.contains("@interface NSObject"))
        let typeInfo = try #require(document["typeInfo"] as? [String: Any])
        #expect(typeInfo["name"] as? String == "NSObject")
        #expect(typeInfo["imageName"] as? String == "libobjc.A")
        #expect(captured.standardError.isEmpty)
    }

    @Test("The text rendering of an interface is the interface itself")
    func interfaceAsText() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths, json: false)

        try await runner.run(.interface(InterfaceCommand(image: "libobjc.A", typeName: "NSObject")))

        #expect(captured.standardOutput.hasPrefix("@interface NSObject") || captured.standardOutput.contains("\n@interface NSObject"))
        #expect(captured.standardOutput.hasSuffix("\n"))
    }

    @Test("types lists Objective-C classes of libobjc, and --kind narrows them")
    func typesOfLibobjc() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths)

        try await runner.run(.listTypes(ListTypesCommand(image: "libobjc.A", kinds: [.objcClass])))

        let document = try jsonObject(captured.standardOutput)
        let types = try #require(document["types"] as? [[String: Any]])
        #expect(types.contains { $0["name"] as? String == "NSObject" })
        #expect(types.allSatisfy { $0["kind"] as? String == "Objective-C Class" })
        #expect(document["imagePaths"] as? [String] == [TestLocalEngine.libobjcPath])
    }

    @Test("search finds NSObject by substring and by regular expression")
    func searchTypes() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }

        do {
            let (runner, captured) = try makeRunner(paths: paths)
            try await runner.run(.searchTypes(SearchTypesCommand(image: "libobjc.A", query: "nsobj")))
            let types = try #require(try jsonObject(captured.standardOutput)["types"] as? [[String: Any]])
            #expect(types.contains { $0["name"] as? String == "NSObject" })
        }
        do {
            let (runner, captured) = try makeRunner(paths: paths)
            // libobjc defines both the class and the protocol named NSObject;
            // the kind filter picks the class.
            try await runner.run(.searchTypes(SearchTypesCommand(image: "libobjc.A", query: "^NSObject$", isRegularExpression: true, kinds: [.objcClass])))
            let types = try #require(try jsonObject(captured.standardOutput)["types"] as? [[String: Any]])
            #expect(types.map { $0["name"] as? String } == ["NSObject"])
        }
    }

    @Test("members lists addresses of NSObject and honours the member filter")
    func memberAddresses() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths)

        try await runner.run(.memberAddresses(MemberAddressesCommand(image: "libobjc.A", typeName: "NSObject", memberName: "description")))

        let document = try jsonObject(captured.standardOutput)
        let members = try #require(document["members"] as? [[String: Any]])
        #expect(!members.isEmpty)
        #expect(members.allSatisfy { ($0["name"] as? String)?.lowercased().contains("description") == true })
        #expect(members.allSatisfy { ($0["address"] as? String)?.hasPrefix("0x") == true })
    }

    @Test("hierarchy and relationships answer for NSObject")
    func hierarchyAndRelationships() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }

        do {
            let (runner, captured) = try makeRunner(paths: paths)
            try await runner.run(.hierarchy(HierarchyCommand(image: "libobjc.A", typeName: "NSObject")))
            let document = try jsonObject(captured.standardOutput)
            #expect(document["hierarchy"] as? [String] != nil)
        }
        do {
            let (runner, captured) = try makeRunner(paths: paths)
            try await runner.run(.relationships(RelationshipsCommand(image: "libobjc.A", typeName: "NSObject")))
            let document = try jsonObject(captured.standardOutput)
            #expect(document["subclasses"] as? [[String: Any]] != nil)
            #expect(document["conformingTypes"] as? [[String: Any]] != nil)
        }
    }

    @Test("export writes libobjc's headers into the output directory")
    func exportLibobjc() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let outputDirectory = paths.rootDirectory.appendingPathComponent("export", isDirectory: true)
        let (runner, captured) = try makeRunner(paths: paths)

        try await runner.run(.export(ExportCommand(image: "libobjc.A", outputDirectory: outputDirectory.path, objcLayout: .single, swiftLayout: .single, includeMetadata: false)))

        let document = try jsonObject(captured.standardOutput)
        let succeeded = try #require(document["succeeded"] as? Int)
        #expect(succeeded > 0)
        #expect(document["outputDirectory"] as? String == outputDirectory.path)
        let written = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        #expect(written.contains { $0.hasSuffix(".h") })
        // Progress went to standard error, never into the JSON document.
        #expect(captured.standardError.contains("exporting"))
    }

    @Test("A missing type is a typeNotFound failure with exit code 1")
    func missingTypeFails() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths)

        await #expect(throws: ExitCode(1)) {
            try await runner.run(.interface(InterfaceCommand(image: "libobjc.A", typeName: "NoSuchTypeAnywhere")))
        }
        let document = try jsonObject(captured.standardOutput)
        let error = try #require(document["error"] as? [String: Any])
        #expect(error["code"] as? String == "typeNotFound")
    }

    @Test("Without a host and without spawning the exit code is 69")
    func unreachableHostExitCode() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let (runner, captured) = try makeRunner(paths: paths, json: false)

        await #expect(throws: ExitCode(CommandRunner.hostUnavailableExitCode)) {
            try await runner.run(.listImages(ListImagesCommand()))
        }
        #expect(captured.standardError.contains("No CLI host is reachable"))
    }

    @Test("A command against an unserved source fails with sourceUnavailable")
    func unservedSource() async throws {
        let paths = try TemporaryHostDirectory.make()
        defer { TemporaryHostDirectory.remove(paths) }
        let host = try await InProcessHost.startWithSharedEngine(paths: paths)
        defer { Task { await host.stop() } }
        let (runner, captured) = try makeRunner(paths: paths)

        await #expect(throws: ExitCode(1)) {
            try await runner.run(.listImages(ListImagesCommand(source: .attachedProcess(processIdentifier: 1))))
        }
        let error = try #require(try jsonObject(captured.standardOutput)["error"] as? [String: Any])
        #expect(error["code"] as? String == "sourceUnavailable")
    }
}

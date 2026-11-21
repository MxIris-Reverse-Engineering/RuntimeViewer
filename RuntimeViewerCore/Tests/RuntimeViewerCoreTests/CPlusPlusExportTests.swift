import Foundation
import Testing
@testable import RuntimeViewerCore

extension CPlusPlusSectionTests {
    /// Exporting the C++ objects of this process's libc++abi (proposal
    /// `cplusplus-export`). Nested in the C++ suite to share its
    /// serialization: the stores MachOKitExtensions keeps C++ indexes in belong
    /// to the whole process, and a test of that suite drops what they hold.
    @Suite("Export")
    struct Export {
        private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
            let engine = RuntimeEngine(source: .local, engineID: "CPlusPlusExportTests.\(label)")
            try await engine.connect()
            return engine
        }

        private static func options() throws -> RuntimeObjectInterface.GenerationOptions {
            try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: Data("{}".utf8))
        }

        private static func makeDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("CPlusPlusExportTests-\(UUID().uuidString)", isDirectory: true)
        }

        private static func configuration(
            exportingTo directory: URL,
            cPlusPlusFormat: RuntimeInterfaceExportConfiguration.Format = .directory,
            includesCPlusPlusObjects: Bool,
            includeMetadata: Bool = false
        ) throws -> RuntimeInterfaceExportConfiguration {
            if includesCPlusPlusObjects {
                return RuntimeInterfaceExportConfiguration(
                    imagePath: CPlusPlusSectionTests.libcxxabiPath,
                    imageName: "libc++abi",
                    directory: directory,
                    objcFormat: .directory,
                    swiftFormat: .directory,
                    cPlusPlusFormat: cPlusPlusFormat,
                    generationOptions: try options(),
                    includeMetadata: includeMetadata,
                    includesCPlusPlusObjects: true
                )
            }
            // Written the way the command-line tool writes it, which names no C++ parameter.
            return RuntimeInterfaceExportConfiguration(
                imagePath: CPlusPlusSectionTests.libcxxabiPath,
                imageName: "libc++abi",
                directory: directory,
                objcFormat: .directory,
                swiftFormat: .directory,
                generationOptions: try options(),
                includeMetadata: includeMetadata
            )
        }

        private static func export(
            _ configuration: RuntimeInterfaceExportConfiguration,
            on engine: RuntimeEngine
        ) async throws -> RuntimeInterfaceExportResult {
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
            let reporter = RuntimeInterfaceExportReporter()
            async let exporting: Void = engine.exportInterfaces(with: configuration, reporter: reporter)
            var result: RuntimeInterfaceExportResult?
            for await event in reporter.events {
                if case .completed(let completed) = event {
                    result = completed
                }
            }
            try await exporting
            return try #require(result)
        }

        private static func fileNames(in directory: URL) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        }

        private static func object(
            _ name: String,
            _ kind: RuntimeObjectKind,
            children: [RuntimeObject] = []
        ) -> RuntimeObject {
            RuntimeObject(
                name: name,
                displayName: name.components(separatedBy: "::").last ?? name,
                kind: kind,
                imagePath: "/usr/lib/libExample.dylib",
                children: children
            )
        }

        // MARK: - Exporting libc++abi

        @Test func exportLeavesCPlusPlusOutUnlessAsked() async throws {
            let engine = try await Self.makeEngine(#function)
            let directory = Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let result = try await Self.export(
                Self.configuration(exportingTo: directory, includesCPlusPlusObjects: false),
                on: engine
            )

            #expect(result.cPlusPlusCount == 0)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("CPlusPlusHeaders").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("libc++abi.hpp").path))
        }

        @Test func directoryExportWritesCPlusPlusHeaders() async throws {
            let engine = try await Self.makeEngine(#function)
            let directory = Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            _ = try await Self.export(
                Self.configuration(exportingTo: directory, includesCPlusPlusObjects: true),
                on: engine
            )

            let fileNames = try Self.fileNames(in: directory.appendingPathComponent("CPlusPlusHeaders"))
            #expect(fileNames.isSuperset(of: ["std.hpp", "std__exception.hpp", "std__bad_alloc.hpp", "std__bad_array_new_length.hpp"]))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ObjCHeaders/std__exception.hpp").path))
        }

        @Test func singleFileExportCombinesCPlusPlusIntoOneHeader() async throws {
            let engine = try await Self.makeEngine(#function)
            let directory = Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            _ = try await Self.export(
                Self.configuration(exportingTo: directory, cPlusPlusFormat: .singleFile, includesCPlusPlusObjects: true),
                on: engine
            )

            let text = try String(contentsOf: directory.appendingPathComponent("libc++abi.hpp"), encoding: .utf8)
            #expect(text.contains("class std::bad_array_new_length : public std::bad_alloc {"))
            #expect(text.contains("class std::exception {"))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("CPlusPlusHeaders").path))
        }

        @Test func exportedCPlusPlusTextMatchesTheContentPane() async throws {
            let engine = try await Self.makeEngine(#function)
            let directory = Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            _ = try await Self.export(
                Self.configuration(exportingTo: directory, includesCPlusPlusObjects: true),
                on: engine
            )

            let objects = try await engine.objects(in: CPlusPlusSectionTests.libcxxabiPath, includesCPlusPlusObjects: true)
            let badAlloc = try #require(CPlusPlusSectionTests.flattened(objects)["std::bad_alloc"])
            let interface = try #require(try await engine.interface(for: badAlloc, options: Self.options()))
            let exported = try String(
                contentsOf: directory.appendingPathComponent("CPlusPlusHeaders/std__bad_alloc.hpp"),
                encoding: .utf8
            )
            #expect(exported == interface.interfaceString.string)
        }

        @Test func resultCountsCPlusPlusInterfaces() async throws {
            let engine = try await Self.makeEngine(#function)
            let directory = Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let result = try await Self.export(
                Self.configuration(exportingTo: directory, includesCPlusPlusObjects: true),
                on: engine
            )

            let written = try Self.fileNames(in: directory.appendingPathComponent("CPlusPlusHeaders"))
            #expect(result.cPlusPlusCount > 0)
            #expect(result.cPlusPlusCount == written.count)
            #expect(result.succeeded == result.objcCount + result.swiftCount + result.cPlusPlusCount)
        }

        @Test func readmeListsCPlusPlusOnlyWhenIncluded() async throws {
            let engine = try await Self.makeEngine(#function)
            let includingDirectory = Self.makeDirectory()
            let leavingOutDirectory = Self.makeDirectory()
            defer {
                try? FileManager.default.removeItem(at: includingDirectory)
                try? FileManager.default.removeItem(at: leavingOutDirectory)
            }

            let result = try await Self.export(
                Self.configuration(exportingTo: includingDirectory, includesCPlusPlusObjects: true, includeMetadata: true),
                on: engine
            )
            _ = try await Self.export(
                Self.configuration(exportingTo: leavingOutDirectory, includesCPlusPlusObjects: false, includeMetadata: true),
                on: engine
            )

            let including = try String(contentsOf: includingDirectory.appendingPathComponent("README.md"), encoding: .utf8)
            let leavingOut = try String(contentsOf: leavingOutDirectory.appendingPathComponent("README.md"), encoding: .utf8)
            #expect(including.contains("- C++ format: Directory"))
            #expect(including.contains("- C++ interfaces: \(result.cPlusPlusCount)"))
            #expect(!leavingOut.contains("C++"))
        }

        // MARK: - Which objects, under which names

        @Test func nestedObjectsFollowTheirScopeDepthFirst() {
            let tree = Self.object("a", .cPlusPlus(.namespace), children: [
                Self.object("a::B", .cPlusPlus(.class), children: [
                    Self.object("a::B::C", .cPlusPlus(.class)),
                ]),
                Self.object("a::D", .cPlusPlus(.namespace)),
            ])

            #expect(tree.exportedObjects.map(\.name) == ["a", "a::B", "a::B::C", "a::D"])
        }

        @Test func objectiveCAndSwiftObjectsExportOnlyThemselves() {
            let swiftType = Self.object("Outer", .swift(.type(.struct)), children: [
                Self.object("Inner", .swift(.type(.struct))),
            ])
            let objectiveCClass = Self.object("NSThing", .objc(.type(.class)), children: [
                Self.object("NSThing(Extras)", .objc(.category(.class))),
            ])

            #expect(swiftType.exportedObjects.map(\.name) == ["Outer"])
            #expect(objectiveCClass.exportedObjects.map(\.name) == ["NSThing"])
        }

        @Test func cPlusPlusFileNamesUseQualifiedNames() {
            let first = Self.object("a::Impl", .cPlusPlus(.class))
            let second = Self.object("b::Impl", .cPlusPlus(.class))

            #expect(first.exportFileName == "a__Impl.hpp")
            #expect(second.exportFileName == "b__Impl.hpp")
        }

        @Test func globalNamespaceExportsAsGlobalNamespaceFile() {
            let globalNamespace = RuntimeObject(
                name: CPlusPlusObjectTreeBuilder.globalNamespaceName,
                displayName: CPlusPlusObjectTreeBuilder.globalNamespaceDisplayName,
                kind: .cPlusPlus(.namespace),
                imagePath: "/usr/lib/libExample.dylib",
                children: []
            )

            #expect(globalNamespace.exportFileName == "GlobalNamespace.hpp")
        }
    }
}

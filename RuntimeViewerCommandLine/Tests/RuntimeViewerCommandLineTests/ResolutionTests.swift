import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommandLineInterface

/// How `--image` and type names resolve, straight through the executor.
@Suite("Image and type resolution")
struct ResolutionTests {
    private func makeExecutor() async throws -> CommandExecutor {
        CommandExecutor(sourceResolver: LocalSourceResolver(engine: try await TestLocalEngine.shared()))
    }

    @Test("A short name resolves by exact base name, case-insensitively", arguments: ["libobjc.A", "LIBOBJC.A"])
    func shortNameResolves(name: String) async throws {
        let executor = try await makeExecutor()
        let result = try await executor.execute(.listTypes(ListTypesCommand(image: name)))
        guard case .typeList(let list) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(list.imagePaths == [TestLocalEngine.libobjcPath])
    }

    @Test("A short name falls back to a substring of the file name")
    func substringFallback() async throws {
        let executor = try await makeExecutor()
        let result = try await executor.execute(.listTypes(ListTypesCommand(image: "objc.A")))
        guard case .typeList(let list) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(list.imagePaths == [TestLocalEngine.libobjcPath])
    }

    @Test("An unknown image is imageNotFound")
    func unknownImage() async throws {
        let executor = try await makeExecutor()
        await #expect(throws: CommandFailure.self) {
            try await executor.execute(.listTypes(ListTypesCommand(image: "NoSuchImageAnywhere")))
        }
        do {
            _ = try await executor.execute(.listTypes(ListTypesCommand(image: "NoSuchImageAnywhere")))
        } catch let failure as CommandFailure {
            #expect(failure.code == .imageNotFound)
        }
    }

    @Test("Omitting --image searches the loaded images")
    func defaultScopeIsLoadedImages() async throws {
        let executor = try await makeExecutor()
        let result = try await executor.execute(.interface(InterfaceCommand(typeName: "NSObject")))
        guard case .interface(let interface) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(interface.typeInfo.imagePath == TestLocalEngine.libobjcPath)
    }

    @Test("images --loaded lists only what is indexed, and marks it")
    func loadedImages() async throws {
        let executor = try await makeExecutor()
        let result = try await executor.execute(.listImages(ListImagesCommand(loadedOnly: true)))
        guard case .imageList(let list) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(list.images.contains { $0.path == TestLocalEngine.libobjcPath && $0.isLoaded && $0.name == "libobjc.A" })
    }

    @Test("images without --loaded includes the system catalog")
    func catalogImages() async throws {
        let executor = try await makeExecutor()
        // The shared cache lists frameworks under their versioned path
        // (`Foundation.framework/Versions/C/Foundation`).
        let result = try await executor.execute(.listImages(ListImagesCommand(query: "/System/Library/Frameworks/Foundation.framework/")))
        guard case .imageList(let list) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(list.images.contains { $0.name == "Foundation" && $0.path.hasSuffix("/Foundation") })
    }

    @Test("An invalid regular expression is invalidArgument")
    func invalidRegularExpression() async throws {
        let executor = try await makeExecutor()
        do {
            _ = try await executor.execute(.searchTypes(SearchTypesCommand(image: "libobjc.A", query: "(", isRegularExpression: true)))
            Issue.record("Accepted an invalid expression")
        } catch let failure as CommandFailure {
            #expect(failure.code == .invalidArgument)
        }
    }

    @Test("Host commands are not the executor's to answer")
    func hostCommandsRejected() async throws {
        let executor = try await makeExecutor()
        do {
            _ = try await executor.execute(.hostStatus)
            Issue.record("Executed a host command")
        } catch let failure as CommandFailure {
            #expect(failure.code == .internalError)
        }
    }

    @Test("Kind filters map onto runtime object kinds")
    func kindFilters() {
        #expect(TypeKindFilter.objcClass.matches(.objc(.type(.class))))
        #expect(!TypeKindFilter.objcClass.matches(.objc(.type(.protocol))))
        #expect(TypeKindFilter.objcCategory.matches(.objc(.category(.class))))
        #expect(TypeKindFilter.swiftStruct.matches(.swift(.type(.struct))))
        #expect(TypeKindFilter.swiftExtension.matches(.swift(.extension(.enum))))
        #expect(TypeKindFilter.cUnion.matches(.c(.union)))
        #expect(TypeKindFilter.filters([], accept: .c(.struct)))
        #expect(TypeKindFilter.filters([.swiftClass, .objcClass], accept: .objc(.type(.class))))
        #expect(!TypeKindFilter.filters([.swiftClass], accept: .objc(.type(.class))))
    }
}

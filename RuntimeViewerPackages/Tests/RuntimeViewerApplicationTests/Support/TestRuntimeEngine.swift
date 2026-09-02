import Foundation
import RuntimeViewerCore

/// Images every macOS test process already has mapped, so loading them is cheap
/// and `isImageLoaded` is true from the start.
enum TestImages {
    static let libobjc = "/usr/lib/libobjc.A.dylib"
    static let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
}

struct MissingRuntimeObject: Error, CustomStringConvertible {
    let name: String
    let imagePath: String

    var description: String { "\(name) not found among the objects of \(imagePath)" }
}

/// Real in-process engines for the ViewModels whose behaviour is defined by
/// engine answers. `RuntimeEngine` is a concrete actor with no protocol seam,
/// and RuntimeViewerCore's own tests take the same route.
enum TestRuntimeEngine {
    /// One connected engine per test process with libobjc and Foundation
    /// loaded and indexed. Shared because indexing Foundation takes seconds.
    /// Nothing may call `loadImage` on it afterwards: a load broadcasts
    /// `.fullReload` to every sidebar ViewModel bound to the engine.
    private static let sharedEngine = Task<RuntimeEngine, Error> {
        try await makeConnected(
            engineID: "RuntimeViewerApplicationTests.shared",
            loading: [TestImages.libobjc, TestImages.foundation]
        )
    }

    static func shared() async throws -> RuntimeEngine {
        try await sharedEngine.value
    }

    /// A private local engine for tests that change engine state themselves.
    static func makeConnected(engineID: String, loading imagePaths: [String] = []) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    /// A client engine that was never connected. Every request throws
    /// `RequestError.senderConnectionIsLose`, the cheapest deterministic way to
    /// drive a ViewModel's failure path.
    static func makeUnreachable() -> RuntimeEngine {
        RuntimeEngine(
            source: .directTCP(name: "unreachable", host: "127.0.0.1", port: 1, role: .client),
            engineID: "RuntimeViewerApplicationTests.unreachable"
        )
    }
}

extension RuntimeEngine {
    func runtimeObject(named name: String, kind: RuntimeObjectKind, in imagePath: String) async throws -> RuntimeObject {
        let objects = try await objects(in: imagePath)
        guard let match = objects.first(where: { $0.name == name && $0.kind == kind }) else {
            throw MissingRuntimeObject(name: name, imagePath: imagePath)
        }
        return match
    }
}

import Combine
import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RxSwift

/// Images every macOS test process already has mapped, so loading them is cheap
/// and `isImageLoaded` is true from the start.
package enum TestImages {
    package static let libobjc = "/usr/lib/libobjc.A.dylib"
    package static let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
}

package struct MissingRuntimeObject: Error, CustomStringConvertible {
    package let name: String
    package let imagePath: String

    package init(name: String, imagePath: String) {
        self.name = name
        self.imagePath = imagePath
    }

    package var description: String { "\(name) not found among the objects of \(imagePath)" }
}

/// Real in-process engines for the ViewModels whose behaviour is defined by
/// engine answers. `RuntimeEngine` is a concrete actor with no protocol seam,
/// and RuntimeViewerCore's own tests take the same route.
package enum TestRuntimeEngine {
    /// One connected engine per test process with libobjc and Foundation
    /// loaded and indexed. Shared because indexing Foundation takes seconds.
    /// Nothing may call `loadImage` on it afterwards: a load broadcasts
    /// `.fullReload` to every sidebar ViewModel bound to the engine.
    private static let sharedEngine = Task<RuntimeEngine, Error> {
        try await makeConnected(
            engineID: "RuntimeViewerAppTestingSupport.shared",
            loading: [TestImages.libobjc, TestImages.foundation]
        )
    }

    package static func shared() async throws -> RuntimeEngine {
        try await sharedEngine.value
    }

    /// A private local engine for tests that change engine state themselves.
    ///
    /// The cross-reference commands are installed first, as every process that serves an engine
    /// installs them at its entry point: an engine connected before they are has no handler for
    /// them. Installing is idempotent.
    package static func makeConnected(engineID: String, loading imagePaths: [String] = []) async throws -> RuntimeEngine {
        RuntimeCrossReferences.install()
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    /// A private local engine, connected, whose first connection has finished reloading its data.
    ///
    /// That reload goes out from a task `connect()` does not wait for, so it can still land after
    /// `connect()` returns — and empty an interface cache, or reset whatever else follows the
    /// engine's data, all on its own. Subscribed before connecting, it cannot be missed.
    package static func makeConnectedWithItsFirstReloadOver(engineID: String) async throws -> RuntimeEngine {
        RuntimeCrossReferences.install()
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        let firstReload = ReplaySubject<Void>.create(bufferSize: 1)
        let reloadSubscription = engine.dataChangePublisher.sink { change in
            if change == .fullReload(isReloadImageNodes: true) {
                firstReload.onNext(())
            }
        }
        defer { reloadSubscription.cancel() }
        try await engine.connect()
        _ = try await nextValue(from: firstReload)
        return engine
    }

    /// A client engine that was never connected. Every request throws
    /// `RequestError.senderConnectionIsLose`, the cheapest deterministic way to
    /// drive a ViewModel's failure path.
    package static func makeUnreachable() -> RuntimeEngine {
        RuntimeEngine(
            source: .directTCP(name: "unreachable", host: "127.0.0.1", port: 1, role: .client),
            engineID: "RuntimeViewerAppTestingSupport.unreachable"
        )
    }
}

extension RuntimeEngine {
    package func runtimeObject(named name: String, kind: RuntimeObjectKind, in imagePath: String) async throws -> RuntimeObject {
        let objects = try await objects(in: imagePath)
        guard let match = objects.first(where: { $0.name == name && $0.kind == kind }) else {
            throw MissingRuntimeObject(name: name, imagePath: imagePath)
        }
        return match
    }
}

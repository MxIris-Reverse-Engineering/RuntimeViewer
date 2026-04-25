import Foundation
@testable import RuntimeViewerCore

// `@unchecked Sendable` is required because the protocol is `Sendable` and this
// class stores mutable state protected by `NSLock` rather than an actor.
final class MockBackgroundIndexingEngine: BackgroundIndexingEngineRepresenting,
                                          @unchecked Sendable
{
    struct ProgrammedPath: Sendable {
        var isIndexed: Bool = false
        var shouldFailLoad: Error? = nil
        var dependencies: [(installName: String, resolvedPath: String?)] = []
    }

    private let lock = NSLock()
    private var paths: [String: ProgrammedPath] = [:]
    private var loadOrder: [String] = []
    var mainExecutable: String = "/fake/MainApp"

    func program(path: String, _ entry: ProgrammedPath) {
        lock.lock(); defer { lock.unlock() }
        paths[path] = entry
    }

    func loadedOrder() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadOrder
    }

    func isImageIndexed(path: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.isIndexed ?? false
    }

    func loadImageForBackgroundIndexing(at path: String) async throws {
        try await Task.sleep(nanoseconds: 5_000_000)  // force real async
        lock.lock(); defer { lock.unlock() }
        if let err = paths[path]?.shouldFailLoad { throw err }
        var entry = paths[path] ?? ProgrammedPath()
        entry.isIndexed = true
        paths[path] = entry
        loadOrder.append(path)
    }

    func mainExecutablePath() async -> String { mainExecutable }

    func canOpenImage(at path: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths[path] != nil
    }
    func rpaths(for path: String) async -> [String] { [] }
    func dependencies(for path: String)
        async -> [(installName: String, resolvedPath: String?)]
    {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.dependencies ?? []
    }
}

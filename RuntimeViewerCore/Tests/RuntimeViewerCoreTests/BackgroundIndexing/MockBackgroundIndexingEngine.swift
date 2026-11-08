import Foundation
@testable import RuntimeViewerCore

// `@unchecked Sendable` is required because the protocol is `Sendable` and this
// class stores mutable state protected by `NSLock` rather than an actor.
final class MockBackgroundIndexingEngine: RuntimeBackgroundIndexingEngineRepresenting,
                                          @unchecked Sendable
{
    struct ProgrammedPath: Sendable {
        var isIndexed: Bool = false
        var shouldFailLoad: Error? = nil
        var dependencies: [(installName: String, resolvedPath: String?)] = []
        var rpaths: [String] = []
    }

    struct DependenciesCall: Sendable, Equatable {
        var path: String
        var ancestorRpaths: [String]
        var mainExecutablePath: String
    }

    private let lock = NSLock()
    private var paths: [String: ProgrammedPath] = [:]
    private var loadOrder: [String] = []
    private var dependenciesCallLog: [DependenciesCall] = []
    private var reloadCount = 0
    var mainExecutable: String = "/fake/MainApp"

    /// The owners' indexing a borrowed image goes to, by path; empty for an
    /// engine that borrows nothing.
    private var ownerManagersByPath: [String: RuntimeBackgroundIndexingManager] = [:]
    /// The paths this engine's owners keep, borrowed or not.
    private var sharedCachePaths: Set<String> = []
    /// Programmed paths that cannot be opened until they are loaded — a
    /// shared cache image no process loaded yet.
    private var unloadedPaths: Set<String> = []
    let borrowerName: String

    init(borrowerName: String = "") {
        self.borrowerName = borrowerName
    }

    /// Makes `path` a borrowed image whose owner indexes it through `manager`.
    func borrow(_ path: String, from manager: RuntimeBackgroundIndexingManager) {
        lock.withLock {
            ownerManagersByPath[path] = manager
            sharedCachePaths.insert(path)
        }
    }

    /// Makes `path` a shared cache image this engine keeps.
    func ownSharedCacheImage(_ path: String) {
        _ = lock.withLock { sharedCachePaths.insert(path) }
    }

    /// Makes a programmed `path` unopenable until it is loaded.
    func leaveUnloaded(_ path: String) {
        _ = lock.withLock { unloadedPaths.insert(path) }
    }

    func ownerBackgroundIndexingManager(forImageAt path: String) async -> RuntimeBackgroundIndexingManager? {
        lock.withLock { ownerManagersByPath[path] }
    }

    func isOwnedSharedCacheImage(_ path: String) -> Bool {
        lock.withLock { sharedCachePaths.contains(path) }
    }

    func program(path: String, _ entry: ProgrammedPath) {
        lock.lock(); defer { lock.unlock() }
        paths[path] = entry
    }

    func loadedOrder() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadOrder
    }

    func dependenciesCalls() -> [DependenciesCall] {
        lock.lock(); defer { lock.unlock() }
        return dependenciesCallLog
    }

    /// How many times the manager asked the engine to re-read its data.
    func reloadDataCount() -> Int {
        lock.withLock { reloadCount }
    }

    func reloadDataAfterBackgroundIndexing() async {
        lock.withLock { reloadCount += 1 }
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
        unloadedPaths.remove(path)
        loadOrder.append(path)
    }

    func mainExecutablePath() async -> String { mainExecutable }

    func canOpenImage(at path: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths[path] != nil && !unloadedPaths.contains(path)
    }
    func rpaths(for path: String) async -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths[path]?.rpaths ?? []
    }
    func dependencies(for path: String,
                      ancestorRpaths: [String],
                      mainExecutablePath: String)
        async -> [(installName: String, resolvedPath: String?)]
    {
        lock.lock(); defer { lock.unlock() }
        dependenciesCallLog.append(.init(path: path,
                                         ancestorRpaths: ancestorRpaths,
                                         mainExecutablePath: mainExecutablePath))
        // An image the process has not loaded has nothing to read them from.
        guard !unloadedPaths.contains(path) else { return [] }
        return paths[path]?.dependencies ?? []
    }
}

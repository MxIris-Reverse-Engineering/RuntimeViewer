/// Abstraction seam for `RuntimeBackgroundIndexingManager` to interact with a
/// `RuntimeEngine`. Lets tests swap in a fake engine without real dyld I/O.
///
/// Methods that proxy to remote sources via `RuntimeEngine.request { ... } remote: { ... }`
/// are `async throws` because the XPC / TCP transport can fail. Pure-local
/// queries (`canOpenImage`) stay non-throwing.
///
/// Note: the protocol intentionally does NOT expose `MachOImage` —— that type
/// is a non-Sendable struct (contains unsafe pointers); returning it across
/// actor boundaries triggers Swift 6 strict-concurrency errors. Callers that
/// only need to gate recursion can use `canOpenImage(at:)` instead.
///
/// Conformance is `Sendable` only —— no `AnyObject` constraint. The manager
/// holds the engine by value (`engine: any BackgroundIndexingEngineRepresenting`),
/// no `weak`/`unowned` is needed, and `actor RuntimeEngine`'s conformance
/// would otherwise depend on the Swift 5.7+ "actor satisfies AnyObject" edge
/// behavior unnecessarily.
protocol BackgroundIndexingEngineRepresenting: Sendable {
    func isImageIndexed(path: String) async throws -> Bool
    func loadImageForBackgroundIndexing(at path: String) async throws
    func mainExecutablePath() async throws -> String
    /// Whether the image at `path` can be opened as a MachO. Pure local check.
    func canOpenImage(at path: String) async -> Bool
    /// Returns the LC_RPATH entries for the image at `path`. Empty when the
    /// image cannot be opened.
    func rpaths(for path: String) async throws -> [String]
    /// Returns the resolved dependency dylib paths for the image at `path`,
    /// excluding lazy-load entries. May return nil `resolvedPath` entries for
    /// unresolved install names; the caller marks them failed.
    func dependencies(for path: String)
        async throws -> [(installName: String, resolvedPath: String?)]
}

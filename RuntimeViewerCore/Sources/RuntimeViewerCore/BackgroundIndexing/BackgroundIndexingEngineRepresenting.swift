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
/// Conformance is `AnyObject, Sendable` so the manager can hold the engine via
/// `unowned let engine`. The engine owns the manager
/// (`RuntimeEngine.backgroundIndexingManager`); making the back-reference
/// non-retaining breaks the cycle that would otherwise leak engine + manager
/// + section caches on every source switch.
protocol BackgroundIndexingEngineRepresenting: AnyObject, Sendable {
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
    ///
    /// `ancestorRpaths` are the LC_RPATH entries collected from every loader
    /// walking up the chain to the main executable. dyld's real `@rpath/...`
    /// resolution searches the union of the image's own LC_RPATH and the
    /// LC_RPATH of every loader in the chain, so a child framework that has
    /// no LC_RPATH but is loaded via the host's LC_RPATH still resolves at
    /// runtime. Pass `[]` for the root image; the BFS in
    /// `RuntimeBackgroundIndexingManager.expandDependencyGraph` accumulates
    /// each visited image's own rpaths into the value passed to its children.
    func dependencies(for path: String, ancestorRpaths: [String])
        async throws -> [(installName: String, resolvedPath: String?)]
}

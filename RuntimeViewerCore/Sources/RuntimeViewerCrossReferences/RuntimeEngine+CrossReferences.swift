public import RuntimeViewerCore

extension RuntimeEngine {
    /// What `subject` references — its callees — decoding that function only.
    ///
    /// An engine whose process predates this module has no handler for the
    /// command, and the call throws.
    public func callees(
        of subject: RuntimeCrossReferenceSubject,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions()
    ) async throws -> RuntimeCrossReferenceQueryResult {
        try await dispatch(RuntimeCrossReferences.CalleesCommand(subject: subject, options: options))
    }

    /// Who references `subject` within `scope` — its callers — among the
    /// images the engine has indexed; an image named that is not indexed is
    /// an error.
    ///
    /// The images that cannot reference the subject are filtered out first —
    /// by the names they import (a C or Objective-C function's, or one
    /// another image re-exports it under), by the images they link (a Swift
    /// function's), or by the selectors they reference — and the rest are
    /// scanned in the engine's process, as many at a time as
    /// ``RuntimeCrossReferenceQueryOptions/maximumConcurrentScans`` allows.
    /// `reportProgress` hears after each image with what it held, so a
    /// caller that gives up early keeps those; cancelling the caller stops the
    /// scan where it runs.
    public func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope = .indexedImages,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions(),
        reportProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferenceQueryResult {
        try await dispatch(RuntimeCrossReferences.CallersCommand(subject: subject, scope: scope, options: options), onProgress: reportProgress)
    }

    /// Which functions reference the type `object` within `scope`: an
    /// Objective-C class, or a Swift struct, enum or class.
    ///
    /// A reference is an instruction that takes the class or the type's
    /// metadata — by address, through a GOT slot, by calling its metadata
    /// accessor — or instantiates a mangled name that names the type. Scanned
    /// and reported like ``callers(of:in:options:reportProgress:)``.
    public func typeReferences(
        to object: RuntimeObject,
        in scope: RuntimeCrossReferenceScope = .indexedImages,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions(),
        reportProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferenceQueryResult {
        try await dispatch(RuntimeCrossReferences.TypeReferencesCommand(object: object, scope: scope, options: options), onProgress: reportProgress)
    }

    /// Prepares the cross references of an image the engine has indexed,
    /// ahead of the queries that will read them: the engine's process scans
    /// the image once and keeps what callers and type queries read, so that
    /// a query naming ``RuntimeCrossReferenceQueryOptions/preparedIndexByteLimit``
    /// answers from it without scanning. An image already prepared, or being
    /// prepared for a query, is not prepared again.
    ///
    /// `reportProgress` hears how many of the image's functions are scanned
    /// as the scan goes. Throws `CancellationError` when cancelled — which
    /// stops the preparation where it runs, unless a query waits for it — and
    /// ``RuntimeCrossReferenceError/imageNotIndexed(path:)`` for an image the
    /// engine has not indexed.
    public func prepareCrossReferences(
        forImageAt imagePath: String,
        options: RuntimeCrossReferencePreparationOptions,
        reportProgress: (@Sendable (RuntimeCrossReferencePreparationProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferencePreparation {
        switch try await dispatch(RuntimeCrossReferences.PrepareCommand(imagePath: imagePath, options: options), onProgress: reportProgress) {
        case .prepared(let preparation):
            return preparation
        case .cancelled:
            throw CancellationError()
        case .imageNotIndexed:
            throw RuntimeCrossReferenceError.imageNotIndexed(path: imagePath)
        }
    }

    /// Sets the most bytes of prepared cross references the engine's process
    /// keeps, dropping the images queried least recently past it; zero drops
    /// them all.
    public func setPreparedCrossReferenceByteLimit(_ byteLimit: Int) async throws {
        _ = try await dispatch(RuntimeCrossReferences.SetPreparedByteLimitCommand(byteLimit: byteLimit))
    }
}

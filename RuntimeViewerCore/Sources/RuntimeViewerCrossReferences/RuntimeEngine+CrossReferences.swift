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

    /// Who references `subject` within `scope` — its callers.
    ///
    /// The images that cannot reference the subject are filtered out first —
    /// by the symbol they import, or by the selectors they reference — and the
    /// rest are scanned in the engine's process. `reportProgress` hears after
    /// each image with what it held, so a caller that gives up early keeps
    /// those; cancelling the caller stops the scan where it runs.
    public func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope = .allImages,
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
        in scope: RuntimeCrossReferenceScope = .allImages,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions(),
        reportProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferenceQueryResult {
        try await dispatch(RuntimeCrossReferences.TypeReferencesCommand(object: object, scope: scope, options: options), onProgress: reportProgress)
    }
}

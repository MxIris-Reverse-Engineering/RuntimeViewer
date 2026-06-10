import Foundation

// MARK: - User-driven Generic Specialization

extension RuntimeEngine {
    /// Build a `RuntimeSpecializationRequest` for a generic Swift type so the
    /// caller can collect a user selection (concrete arguments) before invoking
    /// `specialize(_:with:)`.
    ///
    /// Bridges to `RuntimeSwiftSection` on the local arm; on a client engine
    /// the request is forwarded to the connected server that owns the indexer.
    /// The wire format is built from public Codable types
    /// (`RuntimeSpecializationRequest`) so the client does not need
    /// `@_spi(Support) SwiftInterface` to deserialize the response.
    public func specializationRequest(for object: RuntimeObject) async throws -> RuntimeSpecializationRequest {
        try await dispatch(SpecializationRequestForObjectRequest(object: object))
    }

    func _specializationRequest(for object: RuntimeObject) async throws -> RuntimeSpecializationRequest {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath) else {
            throw EngineError.imageNotIndexed(imagePath: object.imagePath)
        }
        return try await swiftSection.specializationRequest(for: object)
    }

    /// Run runtime-aware preflight on the user's selection before invoking
    /// `specialize(_:with:)`. Surfaces protocol-conformance / layout /
    /// base-class / same-type mismatches with structured diagnostics so the
    /// UI can show them inline rather than letting `specialize` throw a
    /// generic `specializationFailed`.
    ///
    /// `validation.isValid == true` does not guarantee `specialize` will
    /// succeed (candidate metadata accessors are still evaluated lazily on
    /// that path), but `false` *will* cause `specialize` to throw, so it is
    /// safe to abort early when this returns errors.
    public func runtimePreflight(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeSpecializationValidation {
        try await dispatch(RuntimePreflightRequest(object: object, selection: selection))
    }

    func _runtimePreflight(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeSpecializationValidation {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath) else {
            throw EngineError.imageNotIndexed(imagePath: object.imagePath)
        }
        return try await swiftSection.runtimePreflight(for: object, with: selection)
    }

    /// Specialize the given generic Swift type and register the resulting
    /// concrete `TypeDefinition` as a child of the original generic. Returns
    /// the new `RuntimeObject` representing the specialization so the caller
    /// can synchronously update selection state (e.g. drive
    /// `documentState.selectedRuntimeObject` to the new node) without waiting
    /// for the sidebar reload to settle.
    ///
    /// Emits a fine-grained `.specializationAdded(parent:child:)` event on
    /// `dataChangePublisher` so subscribers (notably the sidebar) can splice
    /// the new child into their existing tree rather than rebuilding from
    /// scratch. On the server arm the same event is forwarded to any
    /// connected client.
    @discardableResult
    public func specialize(
        _ object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeObject {
        try await dispatch(SpecializeRequest(object: object, selection: selection))
    }

    @discardableResult
    func _specialize(
        _ object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeObject {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath) else {
            throw EngineError.imageNotIndexed(imagePath: object.imagePath)
        }
        let runtimeObject = try await swiftSection.specialize(for: object, with: selection)
        broadcast(.specializationAdded(parent: object, child: runtimeObject))
        return runtimeObject
    }

    /// Build an inner `RuntimeSpecializationRequest` for a generic candidate
    /// that the user picked while constructing a `boundGeneric` argument.
    /// Resolves the `candidateID` (`mangleAsString(typeName.node)`) back to a
    /// `TypeDefinition` via the shared sub-indexer aggregate, then reuses
    /// `makeRuntimeSpecializationRequest` so the inner request's wire shape is
    /// identical to the outer-level one.
    public func specializationRequest(
        forCandidateID candidateID: String,
        in imagePath: String
    ) async throws -> RuntimeSpecializationRequest {
        try await dispatch(SpecializationRequestForCandidateRequest(candidateID: candidateID, imagePath: imagePath))
    }

    func _specializationRequest(
        forCandidateID candidateID: String,
        in imagePath: String
    ) async throws -> RuntimeSpecializationRequest {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: imagePath) else {
            throw EngineError.imageNotIndexed(imagePath: imagePath)
        }
        return try await swiftSection.specializationRequest(
            forCandidateID: candidateID,
            in: imagePath
        )
    }
}

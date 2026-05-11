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
        try await request {
            guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath) else {
                throw EngineError.imageNotIndexed(imagePath: object.imagePath)
            }
            return try await swiftSection.specializationRequest(for: object)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .specializationRequest, request: object)
        }
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
        try await runtimePreflight(for: .init(object: object, selection: selection))
    }

    /// Internal (rather than `private`) so that
    /// `RuntimeEngine.setMessageHandlerBinding(forName:of:to:)` in `RuntimeEngine.swift`
    /// can reference `$0.runtimePreflight(for:)` across files. `private` extension
    /// members are only visible within the file declaring the extension.
    func runtimePreflight(for request: SpecializeRequest) async throws -> RuntimeSpecializationValidation {
        try await self.request {
            guard let swiftSection = await swiftSectionFactory.existingSection(for: request.object.imagePath) else {
                throw EngineError.imageNotIndexed(imagePath: request.object.imagePath)
            }
            return try await swiftSection.runtimePreflight(for: request.object, with: request.selection)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .runtimePreflight, request: request)
        }
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
        try await specialize(for: .init(object: object, selection: selection))
    }

    /// Internal (rather than `private`) so that
    /// `RuntimeEngine.setMessageHandlerBinding(forName:of:to:)` in `RuntimeEngine.swift`
    /// can reference `$0.specialize(for:)` across files. `private` extension
    /// members are only visible within the file declaring the extension.
    @discardableResult
    func specialize(for request: SpecializeRequest) async throws -> RuntimeObject {
        try await self.request {
            guard let swiftSection = await swiftSectionFactory.existingSection(for: request.object.imagePath) else {
                throw EngineError.imageNotIndexed(imagePath: request.object.imagePath)
            }
            let runtimeObject = try await swiftSection.specialize(for: request.object, with: request.selection)
            broadcast(.specializationAdded(parent: request.object, child: runtimeObject))
            return runtimeObject
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .specialize, request: request)
        }
    }

    struct SpecializeRequest: Codable, Sendable {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
    }
}

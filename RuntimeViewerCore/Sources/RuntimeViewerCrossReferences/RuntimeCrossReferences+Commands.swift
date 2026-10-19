import RuntimeViewerCore

// The commands run in the process that serves the engine: the analysis reads
// that process's own images, and the dyld shared cache it maps. A host asking
// a remote engine gets the far process's answer through the connection.
extension RuntimeCrossReferences {
    /// What one function references.
    struct CalleesCommand: RuntimeEngineCommand {
        let subject: RuntimeCrossReferenceSubject
        let options: RuntimeCrossReferenceQueryOptions

        static var commandName: String { RuntimeEngine.CommandName.crossReferenceCallees.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeCrossReferenceQueryResult {
            try await CrossReferenceQuery(engine: engine).callees(of: subject, options: options)
        }
    }

    /// Who references a function, a member or a selector.
    struct CallersCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeCrossReferenceQueryResult
        typealias Progress = RuntimeCrossReferenceQueryProgress

        let subject: RuntimeCrossReferenceSubject
        let scope: RuntimeCrossReferenceScope
        let options: RuntimeCrossReferenceQueryOptions

        static var commandName: String { RuntimeEngine.CommandName.crossReferenceCallers.commandName }

        /// New with this module, so every peer that serves it also knows
        /// `cancelRequest`: cancelling a caller stops the scan where it runs.
        static var cancelsAcrossConnections: Bool { true }

        func perform(
            on engine: RuntimeEngine,
            reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
        ) async throws -> RuntimeCrossReferenceQueryResult {
            try await CrossReferenceQuery(engine: engine).callers(of: subject, in: scope, options: options, reportProgress: reportProgress)
        }
    }

    /// Which functions reference a type.
    struct TypeReferencesCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeCrossReferenceQueryResult
        typealias Progress = RuntimeCrossReferenceQueryProgress

        let object: RuntimeObject
        let scope: RuntimeCrossReferenceScope
        let options: RuntimeCrossReferenceQueryOptions

        static var commandName: String { RuntimeEngine.CommandName.crossReferenceTypeReferences.commandName }

        /// New with this module, like the callers: every peer that serves it
        /// also knows `cancelRequest`.
        static var cancelsAcrossConnections: Bool { true }

        func perform(
            on engine: RuntimeEngine,
            reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
        ) async throws -> RuntimeCrossReferenceQueryResult {
            try await CrossReferenceQuery(engine: engine).typeReferences(to: object, in: scope, options: options, reportProgress: reportProgress)
        }
    }

    /// Prepares an image's cross references ahead of the queries.
    struct PrepareCommand: RuntimeEngineProgressCommand {
        typealias Response = RuntimeCrossReferencePreparationOutcome
        typealias Progress = RuntimeCrossReferencePreparationProgress

        let imagePath: String
        let options: RuntimeCrossReferencePreparationOptions

        static var commandName: String { RuntimeEngine.CommandName.crossReferencePrepare.commandName }

        /// New with the preparation, so every peer that serves it also knows
        /// `cancelRequest`: a host that stops waiting stops the preparation
        /// where it runs, unless a query still waits for it.
        static var cancelsAcrossConnections: Bool { true }

        func perform(
            on engine: RuntimeEngine,
            reportProgress: @escaping @Sendable (RuntimeCrossReferencePreparationProgress) async -> Void
        ) async throws -> RuntimeCrossReferencePreparationOutcome {
            do {
                return .prepared(try await CrossReferenceQuery(engine: engine).prepare(imageAt: imagePath, options: options, reportProgress: reportProgress))
            } catch is CancellationError {
                return .cancelled
            } catch RuntimeCrossReferenceError.imageNotIndexed {
                return .imageNotIndexed
            }
        }
    }

    /// Sets how many bytes of prepared cross references the process keeps.
    struct SetPreparedByteLimitCommand: RuntimeEngineCommand {
        let byteLimit: Int

        static var commandName: String { RuntimeEngine.CommandName.crossReferenceSetPreparedByteLimit.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            CrossReferenceQuery(engine: engine).setPreparedByteLimit(byteLimit)
            return RuntimeEngineEmpty()
        }
    }
}

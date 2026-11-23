import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerCrossReferences

/// Runs engine-backed commands against whatever engine the resolver hands out,
/// and passes the source commands (`sources`, `attach`, `detach`) through to it.
///
/// Written against `RuntimeEngine` only, so the same executor serves a remote
/// engine once a resolver produces one. Host commands (`hostStatus`,
/// `shutdownHost`) are the host's own business and are rejected here.
@Loggable
public actor CommandExecutor {
    public typealias ProgressHandler = @Sendable (CommandProgress) async -> Void

    private let sourceResolver: any SourceResolving
    private let applicationOptionsReader: any ApplicationOptionsReading

    public init(sourceResolver: any SourceResolving, applicationOptionsReader: any ApplicationOptionsReading = ApplicationOptionsReader()) {
        self.sourceResolver = sourceResolver
        self.applicationOptionsReader = applicationOptionsReader
    }

    /// Executes a command. Every error surfaces as a ``CommandFailure``.
    public func execute(_ command: Command, progress: ProgressHandler? = nil) async throws -> CommandResult {
        do {
            return try await perform(command, progress: progress)
        } catch {
            throw CommandFailure.wrapping(error)
        }
    }

    /// Images the served engines have indexed, for `host status`.
    public func loadedImagePaths() async -> [String] {
        await sourceResolver.loadedImagePaths()
    }

    public func shutdown() async {
        await sourceResolver.shutdown()
    }

    private func perform(_ command: Command, progress: ProgressHandler?) async throws -> CommandResult {
        switch command {
        case .listImages(let command):
            return .imageList(try await listImages(command))
        case .loadImage(let command):
            return .imageLoaded(try await loadImage(command))
        case .listTypes(let command):
            return .typeList(try await listTypes(command))
        case .searchTypes(let command):
            return .typeList(try await searchTypes(command))
        case .interface(let command):
            return .interface(try await interface(command))
        case .hierarchy(let command):
            return .hierarchy(try await hierarchy(command))
        case .relationships(let command):
            return .relationships(try await relationships(command))
        case .memberAddresses(let command):
            return .memberAddresses(try await memberAddresses(command))
        case .specialize(let command):
            return try await specialize(command)
        case .export(let command):
            return .export(try await export(command, progress: progress))
        case .callers(let command):
            return .crossReferences(try await crossReferenceFailures { try await callers(command, progress: progress) })
        case .callees(let command):
            return .crossReferences(try await crossReferenceFailures { try await callees(command) })
        case .typeReferences(let command):
            return .crossReferences(try await crossReferenceFailures { try await typeReferences(command, progress: progress) })
        case .symbolicate(let command):
            return .symbolications(try await crossReferenceFailures { try await symbolicate(command) })
        case .listSources(let command):
            return .sources(try await listSources(command))
        case .attach(let command):
            return .attached(try await sourceResolver.attach(command.target, progress: progress ?? { _ in }))
        case .detach(let command):
            return .detached(try await sourceResolver.detach(command.source))
        case .hostStatus, .shutdownHost:
            throw CommandFailure(code: .internalError, message: "Host commands are answered by the host, not by the executor.")
        }
    }

    // MARK: - Images

    private func listImages(_ command: ListImagesCommand) async throws -> ImageListResult {
        let engine = try await sourceResolver.resolve(command.source)
        let loaded = await engine.loadedImagePaths
        var paths: [String]
        if command.loadedOnly {
            paths = loaded.sorted()
        } else {
            var seen: Set<String> = []
            paths = []
            for path in await engine.imageList + ImageResolver(engine: engine).catalogPaths() where seen.insert(path).inserted {
                paths.append(path)
            }
            paths.sort()
        }
        if let query = command.query?.lowercased(), !query.isEmpty {
            paths = paths.filter { $0.lowercased().contains(query) }
        }
        return ImageListResult(images: paths.map { path in
            ImageInfo(path: path, name: ImageResolver.baseName(of: path), isLoaded: loaded.contains(path))
        })
    }

    private func loadImage(_ command: LoadImageCommand) async throws -> LoadImageResult {
        let engine = try await sourceResolver.resolve(command.source)
        let resolver = ImageResolver(engine: engine)
        let path = command.imagePath
        let wasAlreadyLoaded = (try? await engine.isImageLoaded(path: path)) ?? false
        try await resolver.ensureLoaded(path)
        let objects = try await objects(in: [path], engine: engine).flatMap(\.objects)
        return LoadImageResult(
            imagePath: path,
            imageName: ImageResolver.baseName(of: path),
            objectCount: objects.count,
            wasAlreadyLoaded: wasAlreadyLoaded
        )
    }

    // MARK: - Types

    private func listTypes(_ command: ListTypesCommand) async throws -> TypeListResult {
        let engine = try await sourceResolver.resolve(command.source)
        let paths = try await ImageResolver(engine: engine).resolveImagePaths(command.image)
        let collected = try await objects(in: paths, engine: engine)
        let types = collected
            .flatMap(\.objects)
            .filter { TypeKindFilter.filters(command.kinds, accept: $0.kind) }
            .map(TypeInfo.init)
        return TypeListResult(imagePaths: collected.map(\.path), types: types)
    }

    private func searchTypes(_ command: SearchTypesCommand) async throws -> TypeListResult {
        let engine = try await sourceResolver.resolve(command.source)
        let paths = try await ImageResolver(engine: engine).resolveImagePaths(command.image)
        let collected = try await objects(in: paths, engine: engine)
        let matches: (RuntimeObject) -> Bool
        if command.isRegularExpression {
            let regularExpression: Regex<AnyRegexOutput>
            do {
                regularExpression = try Regex(command.query)
            } catch {
                throw CommandFailure(code: .invalidArgument, message: "'\(command.query)' is not a valid regular expression: \(error.localizedDescription)")
            }
            matches = { object in
                object.name.contains(regularExpression) || object.displayName.contains(regularExpression)
            }
        } else {
            let needle = command.query.lowercased()
            matches = { object in
                object.name.lowercased().contains(needle) || object.displayName.lowercased().contains(needle)
            }
        }
        let types = collected
            .flatMap(\.objects)
            .filter { TypeKindFilter.filters(command.kinds, accept: $0.kind) && matches($0) }
            .map(TypeInfo.init)
        return TypeListResult(imagePaths: collected.map(\.path), types: types)
    }

    // MARK: - One type

    private func interface(_ command: InterfaceCommand) async throws -> InterfaceResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let interfaceText = try await interfaceText(for: object, options: command.options, engine: engine)
        return InterfaceResult(typeInfo: TypeInfo(object), interfaceText: interfaceText)
    }

    private func hierarchy(_ command: HierarchyCommand) async throws -> HierarchyResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let hierarchy = try await engine.hierarchy(for: object)
        return HierarchyResult(typeInfo: TypeInfo(object), hierarchy: hierarchy)
    }

    private func relationships(_ command: RelationshipsCommand) async throws -> RelationshipsResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let relationships = try await engine.relationships(for: object)
        return RelationshipsResult(
            typeInfo: TypeInfo(object),
            subclasses: relationships.subclasses.map(TypeInfo.init),
            conformingTypes: relationships.conformingTypes.map(TypeInfo.init)
        )
    }

    private func memberAddresses(_ command: MemberAddressesCommand) async throws -> MemberAddressesResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let members = try await engine.memberAddresses(for: object, memberName: command.memberName)
        return MemberAddressesResult(
            typeInfo: TypeInfo(object),
            members: members.map { MemberAddress(name: $0.name, kind: $0.kind, symbolName: $0.symbolName, address: $0.address) }
        )
    }

    // MARK: - Cross references

    private func callers(_ command: CallersCommand, progress: ProgressHandler?) async throws -> CrossReferencesResult {
        let engine = try await sourceResolver.resolve(command.source)
        let imagePath = try await crossReferenceImagePath(command.image, engine: engine)
        let subject = try await crossReferenceSubject(command.target, isSelector: command.isSelector, imagePath: imagePath, engine: engine)
        let options = RuntimeCrossReferenceQueryOptions(receiverClassName: command.receiverClassName, resultLimit: command.limit)
        let result = try await engine.callers(
            of: subject,
            in: try crossReferenceScope(command.scope, imagePath: imagePath),
            options: options,
            reportProgress: crossReferenceProgress(progress)
        )
        return CrossReferencesResult(subject: Self.description(of: subject), references: result.references.map(RuntimeCrossReferenceRow.init), isComplete: result.isComplete)
    }

    private func callees(_ command: CalleesCommand) async throws -> CrossReferencesResult {
        let engine = try await sourceResolver.resolve(command.source)
        let imagePath = try await crossReferenceImagePath(command.image, engine: engine)
        let subject = try await crossReferenceSubject(command.target, isSelector: false, imagePath: imagePath, engine: engine)
        let options = RuntimeCrossReferenceQueryOptions(includesRuntimeHelperCalls: command.includesRuntimeHelperCalls, resultLimit: command.limit)
        let result = try await engine.callees(of: subject, options: options)
        return CrossReferencesResult(subject: Self.description(of: subject), references: result.references.map(RuntimeCrossReferenceRow.init), isComplete: result.isComplete)
    }

    private func typeReferences(_ command: TypeReferencesCommand, progress: ProgressHandler?) async throws -> CrossReferencesResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let imagePath = try await crossReferenceImagePath(command.image, engine: engine)
        let result = try await engine.typeReferences(
            to: object,
            in: try crossReferenceScope(command.scope, imagePath: imagePath),
            options: RuntimeCrossReferenceQueryOptions(resultLimit: command.limit),
            reportProgress: crossReferenceProgress(progress)
        )
        return CrossReferencesResult(subject: object.displayName, references: result.references.map(RuntimeCrossReferenceRow.init), isComplete: result.isComplete)
    }

    private func symbolicate(_ command: SymbolicateCommand) async throws -> SymbolicationsResult {
        let engine = try await sourceResolver.resolve(command.source)
        let imagePath = try await crossReferenceImagePath(command.image, engine: engine)
        let symbolications = try await engine.symbolicate(command.addresses, inImageAt: imagePath)
        return SymbolicationsResult(symbolications: symbolications.map(RuntimeAddressSymbolicationRow.init))
    }

    /// The one image `--image` names, loaded and indexed — a cross-reference
    /// query reads indexed images only.
    private func crossReferenceImagePath(_ image: String?, engine: RuntimeEngine) async throws -> String? {
        guard let image else { return nil }
        return try await ImageResolver(engine: engine).resolveImagePaths(image).first
    }

    private func crossReferenceSubject(_ target: String, isSelector: Bool, imagePath: String?, engine: RuntimeEngine) async throws -> RuntimeCrossReferenceSubject {
        try await RuntimeCrossReferenceTargetResolution.subject(forTarget: target, isSelector: isSelector, imagePath: imagePath, engine: engine) { typeName in
            let paths = try await ImageResolver(engine: engine).resolveImagePaths(imagePath)
            for (_, objects) in try await objects(in: paths, engine: engine) {
                if let found = RuntimeObject.find(named: typeName, in: objects) { return found }
            }
            return nil
        }
    }

    private func crossReferenceScope(_ scope: CrossReferenceScopeChoice, imagePath: String?) throws -> RuntimeCrossReferenceScope {
        switch scope {
        case .indexed:
            return .indexedImages
        case .image:
            guard let imagePath else {
                throw CommandFailure(code: .invalidArgument, message: "--scope image reads the image --image names; name one.")
            }
            return .image(path: imagePath)
        }
    }

    private func crossReferenceProgress(_ progress: ProgressHandler?) -> (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? {
        guard let progress else { return nil }
        return { report in
            await progress(CommandProgress(phase: "scanning", current: report.scannedImageCount, total: report.totalImageCount))
        }
    }

    /// The query's errors, as the command line words and codes them.
    private func crossReferenceFailures<Outcome>(_ body: () async throws -> Outcome) async throws -> Outcome {
        do {
            return try await body()
        } catch let error as RuntimeCrossReferenceError {
            switch error {
            case .unsupportedArchitecture:
                throw CommandFailure(code: .crossReferencesUnavailable, message: error.localizedDescription)
            case .imageNotFound, .imageNotIndexed:
                throw CommandFailure(code: .imageNotFound, message: error.localizedDescription)
            case .functionNotFound, .memberNotFound, .targetNotFound:
                throw CommandFailure(code: .targetNotFound, message: error.localizedDescription)
            case .typeNotFound:
                throw CommandFailure(code: .typeNotFound, message: error.localizedDescription)
            case .selectorHasNoCallees, .addressNeedsImage, .ambiguousTarget:
                throw CommandFailure(code: .invalidArgument, message: error.localizedDescription + Self.imageHint(for: error))
            }
        } catch let error as RuntimeNetworkRequestError where error.isUnknownCommand {
            throw CommandFailure(code: .crossReferencesUnavailable, message: "This source cannot answer cross references: it reads a file, or its process predates them.")
        }
    }

    private static func imageHint(for error: RuntimeCrossReferenceError) -> String {
        switch error {
        case .addressNeedsImage, .ambiguousTarget: " Pass --image."
        default: ""
        }
    }

    private static func description(of subject: RuntimeCrossReferenceSubject) -> String {
        switch subject {
        case .function(let imagePath, let address):
            "0x\(String(address, radix: 16)) in \(ImageResolver.baseName(of: imagePath))"
        case .member(let member):
            member.kind.isObjC ? "\(member.isStatic ? "+" : "-")[\(member.object.displayName) \(member.name)]" : "\(member.object.displayName).\(member.name)"
        case .selector(let selector):
            selector
        }
    }

    // MARK: - Specialization

    private func specialize(_ command: SpecializeCommand) async throws -> CommandResult {
        let engine = try await sourceResolver.resolve(command.source)
        let object = try await findType(command.typeName, image: command.image, engine: engine)
        let request: RuntimeSpecializationRequest
        do {
            request = try await engine.specializationRequest(for: object)
        } catch {
            throw CommandFailure(code: .specializationFailed, message: "'\(object.displayName)' cannot be specialized: \(error.localizedDescription)")
        }

        if command.listOnly || command.arguments.isEmpty {
            let parameters = request.parameters.map { parameter in
                SpecializationParameter(
                    name: parameter.name,
                    displayDescription: parameter.displayDescription,
                    candidates: parameter.candidates.map { candidate in
                        SpecializationCandidate(
                            displayName: candidate.displayName,
                            imagePath: candidate.imagePath,
                            imageName: ImageResolver.baseName(of: candidate.imagePath),
                            kind: String(describing: candidate.kind),
                            isGeneric: candidate.isGeneric
                        )
                    }
                )
            }
            return .specializationParameters(SpecializationParametersResult(typeInfo: TypeInfo(object), parameters: parameters))
        }

        let parameterNames = request.parameters.map(\.name)
        let unknownArguments = Set(command.arguments.keys).subtracting(parameterNames).sorted()
        guard unknownArguments.isEmpty else {
            throw CommandFailure(
                code: .invalidArgument,
                message: "'\(object.displayName)' has no generic parameter named \(unknownArguments.map { "'\($0)'" }.joined(separator: ", ")). Its parameters are: \(parameterNames.joined(separator: ", "))."
            )
        }

        var selection = RuntimeSpecializationSelection()
        for parameter in request.parameters {
            guard let argument = command.arguments[parameter.name] else {
                throw CommandFailure(
                    code: .invalidArgument,
                    message: "Missing an argument for generic parameter '\(parameter.name)'. Pass --argument \(parameter.name)=<Type>; run with --list to see the candidates."
                )
            }
            let candidate = Self.candidate(named: argument, among: parameter.candidates)
            guard let candidate else {
                throw CommandFailure(
                    code: .invalidArgument,
                    message: "'\(argument)' is not a candidate for generic parameter '\(parameter.name)'. Run with --list to see the candidates."
                )
            }
            selection.setArgument(.candidate(candidate), for: parameter.name)
        }

        let validation: RuntimeSpecializationValidation
        do {
            validation = try await engine.runtimePreflight(for: object, with: selection)
        } catch {
            throw CommandFailure(code: .specializationFailed, message: "Preflight failed: \(error.localizedDescription)")
        }
        guard validation.isValid else {
            let reasons = validation.errors.map(\.description).joined(separator: "; ")
            throw CommandFailure(code: .specializationFailed, message: "The selected arguments do not fit '\(object.displayName)': \(reasons)")
        }

        let specialized: RuntimeObject
        do {
            specialized = try await engine.specialize(object, with: selection)
        } catch {
            throw CommandFailure(code: .specializationFailed, message: "Specialization failed: \(error.localizedDescription)")
        }
        let interfaceText = try await interfaceText(for: specialized, options: command.options, engine: engine)
        return .specialized(SpecializedInterfaceResult(
            typeInfo: TypeInfo(specialized),
            interfaceText: interfaceText,
            warnings: validation.warnings.map(\.description)
        ))
    }

    /// The candidate an `--argument Param=Type` names: exact display name
    /// first, then case-insensitively.
    ///
    /// Ordered first, for the reason `ImageResolver.match` is: the engine's
    /// order is not something the user can predict, so two candidates sharing a
    /// display name — which `Candidate.imagePath` exists to tell apart — must
    /// not resolve differently from one run to the next. The order is the
    /// type's own `ComparableBuildable` one, so the type picker in the app and
    /// `--argument` here settle on the same candidate.
    static func candidate(
        named argument: String,
        among candidates: [RuntimeSpecializationRequest.Candidate]
    ) -> RuntimeSpecializationRequest.Candidate? {
        let ordered = candidates.sorted()
        return ordered.first { $0.displayName == argument }
            ?? ordered.first { $0.displayName.lowercased() == argument.lowercased() }
    }

    // MARK: - Export

    private func export(_ command: ExportCommand, progress: ProgressHandler?) async throws -> ExportResult {
        let engine = try await sourceResolver.resolve(command.source)
        let paths = try await ImageResolver(engine: engine).resolveImagePaths(command.image)
        guard paths.count == 1, let imagePath = paths.first else {
            throw CommandFailure(code: .invalidArgument, message: "Export needs exactly one image; '\(command.image)' resolved to \(paths.count).")
        }
        let directory = URL(fileURLWithPath: command.outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CommandFailure(code: .exportFailed, message: "Could not create '\(directory.path)': \(error.localizedDescription)")
        }
        let imageName = ImageResolver.baseName(of: imagePath)
        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: imagePath,
            imageName: imageName,
            directory: directory,
            objcFormat: command.objcLayout.exportFormat,
            swiftFormat: command.swiftLayout.exportFormat,
            generationOptions: await generationOptions(for: command.options),
            includeMetadata: command.includeMetadata
        )

        let reporter = RuntimeInterfaceExportReporter()
        let exportTask = Task {
            try await engine.exportInterfaces(with: configuration, reporter: reporter)
        }

        var completed: RuntimeInterfaceExportResult?
        var phaseFailures: [String] = []
        // The export runs in an unstructured Task, which neither inherits this
        // task's cancellation nor passes it on through `.value`. Without the
        // handler below, a cancelled export keeps writing files until the whole
        // image is done — and the host's shutdown drain waits for it, because
        // the request only finishes when the export does. Core's export loop
        // checks `Task.checkCancellation()`, so cancelling is enough to stop it.
        await withTaskCancellationHandler {
            for await event in reporter.events {
                switch event {
                case .phaseStarted(let phase):
                    await progress?(CommandProgress(phase: phase.progressName))
                case .objectStarted(let object, let current, let total):
                    // One frame per object would be thousands for a large image;
                    // the client only needs to see movement.
                    if current == 1 || current == total || current % 25 == 0 {
                        await progress?(CommandProgress(phase: "exporting", current: current, total: total, detail: object.displayName))
                    }
                case .phaseFailed(let phase, let error):
                    phaseFailures.append("\(phase.progressName): \(error.localizedDescription)")
                case .completed(let result):
                    completed = result
                case .phaseCompleted, .objectCompleted, .objectFailed:
                    break
                }
            }
        } onCancel: {
            exportTask.cancel()
        }

        do {
            try await exportTask.value
            // Cancellation that lands after Core's last `checkCancellation` —
            // during the writing phase, or on an image with few objects — lets
            // the export finish normally while the event loop above has already
            // stopped, leaving `completed` nil. Without this the command would
            // report `exportFailed`, "finished without a result", for what the
            // caller itself asked to stop.
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CommandFailure(code: .cancelled, message: "The export of '\(imageName)' was cancelled.")
        } catch {
            throw CommandFailure(code: .exportFailed, message: "Export of '\(imageName)' failed: \(error.localizedDescription)")
        }
        guard let completed else {
            throw CommandFailure(code: .exportFailed, message: "Export of '\(imageName)' finished without a result." + (phaseFailures.isEmpty ? "" : " " + phaseFailures.joined(separator: "; ")))
        }
        if !phaseFailures.isEmpty {
            throw CommandFailure(code: .exportFailed, message: "Export of '\(imageName)' did not complete: \(phaseFailures.joined(separator: "; "))")
        }
        return ExportResult(
            imagePath: imagePath,
            imageName: imageName,
            outputDirectory: directory.path,
            succeeded: completed.succeeded,
            failed: completed.failed,
            objcCount: completed.objcCount,
            swiftCount: completed.swiftCount,
            totalDuration: completed.totalDuration
        )
    }

    // MARK: - Sources

    /// How long the source list must stay unchanged before a `--wait` answers
    /// early. Long enough for a peer that was just discovered to finish its
    /// handshake (connect, two seconds of preflight, engine list).
    static let sourcesSettlePeriod: Duration = .seconds(3)
    static let sourcesPollInterval: Duration = .milliseconds(500)

    private func listSources(_ command: ListSourcesCommand) async throws -> SourcesResult {
        var latest = await sourceResolver.listSources()
        guard command.waitSeconds > 0 else { return latest }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(command.waitSeconds)
        var stableSince = clock.now
        while clock.now < deadline {
            try await clock.sleep(for: min(Self.sourcesPollInterval, deadline - clock.now))
            let current = await sourceResolver.listSources()
            if current != latest {
                latest = current
                stableSince = clock.now
            } else if clock.now - stableSince >= Self.sourcesSettlePeriod {
                break
            }
        }
        return latest
    }

    // MARK: - Shared steps

    /// Indexes each image and returns its objects. An image that fails to index
    /// is skipped; only when every image fails does the command fail.
    private func objects(in paths: [String], engine: RuntimeEngine) async throws -> [(path: String, objects: [RuntimeObject])] {
        var collected: [(path: String, objects: [RuntimeObject])] = []
        var failures: [String] = []
        for path in paths {
            do {
                collected.append((path, try await engine.objects(in: path)))
            } catch {
                #log(.default, "Could not index \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append("'\(path)': \(error.localizedDescription)")
            }
        }
        if collected.isEmpty, !failures.isEmpty {
            throw CommandFailure(code: .imageLoadFailed, message: "Could not index \(failures.joined(separator: "; "))")
        }
        return collected
    }

    private func findType(_ typeName: String, image: String?, engine: RuntimeEngine) async throws -> RuntimeObject {
        let paths = try await ImageResolver(engine: engine).resolveImagePaths(image)
        for (_, objects) in try await objects(in: paths, engine: engine) {
            if let found = RuntimeObject.find(named: typeName, in: objects) {
                return found
            }
        }
        let scope = image.map { "'\($0)'" } ?? "the \(paths.count) loaded image\(paths.count == 1 ? "" : "s")"
        throw CommandFailure(code: .typeNotFound, message: "No type named '\(typeName)' in \(scope).")
    }

    private func interfaceText(for object: RuntimeObject, options choice: GenerationOptionsChoice, engine: RuntimeEngine) async throws -> String {
        let interface: RuntimeObjectInterface?
        do {
            interface = try await engine.interface(for: object, options: await generationOptions(for: choice))
        } catch {
            throw CommandFailure(code: .internalError, message: "Generating the interface of '\(object.displayName)' failed: \(error.localizedDescription)")
        }
        guard let interface else {
            throw CommandFailure(code: .internalError, message: "The engine produced no interface for '\(object.displayName)'.")
        }
        return interface.interfaceString.string
    }

    /// Every choice waits for the serving process's type index before
    /// printing: a command prints once, so it prints the names the index
    /// resolves rather than the `__C.` ones it would print while the index is
    /// still being built (proposal swift-type-indexing-package).
    private func generationOptions(for choice: GenerationOptionsChoice) async -> RuntimeObjectInterface.GenerationOptions {
        var options: RuntimeObjectInterface.GenerationOptions
        switch choice {
        case .default:
            options = RuntimeObjectInterface.GenerationOptions()
        case .full:
            options = .mcp
        case .application:
            options = await applicationOptionsReader.readGenerationOptions()
        }
        options.waitsForTypeIndex = true
        return options
    }
}

extension ExportLayout {
    var exportFormat: RuntimeInterfaceExportConfiguration.Format {
        switch self {
        case .single: return .singleFile
        case .directory: return .directory
        }
    }
}

extension RuntimeInterfaceExportEvent.Phase {
    var progressName: String {
        switch self {
        case .preparing: return "preparing"
        case .exporting: return "exporting"
        case .writing: return "writing"
        }
    }
}

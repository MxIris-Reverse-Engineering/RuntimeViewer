import Foundation
import FoundationToolbox
import RuntimeViewerCore

/// Runs engine-backed commands against whatever engine the resolver hands out.
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
            let candidate = parameter.candidates.first { $0.displayName == argument }
                ?? parameter.candidates.first { $0.displayName.lowercased() == argument.lowercased() }
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
            generationOptions: generationOptions(for: command.options),
            includeMetadata: command.includeMetadata
        )

        let reporter = RuntimeInterfaceExportReporter()
        let exportTask = Task {
            try await engine.exportInterfaces(with: configuration, reporter: reporter)
        }

        var completed: RuntimeInterfaceExportResult?
        var phaseFailures: [String] = []
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

        do {
            try await exportTask.value
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
            interface = try await engine.interface(for: object, options: generationOptions(for: choice))
        } catch {
            throw CommandFailure(code: .internalError, message: "Generating the interface of '\(object.displayName)' failed: \(error.localizedDescription)")
        }
        guard let interface else {
            throw CommandFailure(code: .internalError, message: "The engine produced no interface for '\(object.displayName)'.")
        }
        return interface.interfaceString.string
    }

    private func generationOptions(for choice: GenerationOptionsChoice) -> RuntimeObjectInterface.GenerationOptions {
        switch choice {
        case .default:
            return RuntimeObjectInterface.GenerationOptions()
        case .full:
            return .mcp
        case .application:
            return applicationOptionsReader.readGenerationOptions()
        }
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

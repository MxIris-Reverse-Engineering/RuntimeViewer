import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerMCPShared
import RuntimeViewerSettings
import Dependencies
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

public actor MCPBridgeServer {
    private let listener: MCPBridgeListener
    private let windowProvider: MCPBridgeWindowProvider

    @Dependency(\.appDefaults)
    private var appDefaults

    public init(windowProvider: MCPBridgeWindowProvider, port: UInt16 = 0) throws {
        self.windowProvider = windowProvider
        self.listener = try MCPBridgeListener(port: port)
    }

    public func start() {
        listener.start { [self] envelope in
            try await self.processRequest(envelope)
        }
    }

    public nonisolated func stop() {
        listener.stop()
    }

    deinit {
        stop()
    }

    // MARK: - Request Routing

    private func processRequest(_ envelope: MCPBridgeEnvelope) async throws -> Data {
        guard let command = MCPBridgeCommand(rawValue: envelope.identifier) else {
            throw MCPBridgeTransportError.decodingFailed
        }

        switch command {
        case .listWindows:
            let response = await handleListWindows()
            return try JSONEncoder().encode(response)

        case .selectedType:
            let request = try envelope.decode(MCPSelectedTypeRequest.self)
            let response = await handleSelectedType(request)
            return try JSONEncoder().encode(response)

        case .typeInterface:
            let request = try envelope.decode(MCPTypeInterfaceRequest.self)
            let response = await handleTypeInterface(request)
            return try JSONEncoder().encode(response)

        case .listTypes:
            let request = try envelope.decode(MCPListTypesRequest.self)
            let response = await handleListTypes(request)
            return try JSONEncoder().encode(response)

        case .searchTypes:
            let request = try envelope.decode(MCPSearchTypesRequest.self)
            let response = await handleSearchTypes(request)
            return try JSONEncoder().encode(response)

        case .grepTypeInterface:
            let request = try envelope.decode(MCPGrepTypeInterfaceRequest.self)
            let response = await handleGrepTypeInterface(request)
            return try JSONEncoder().encode(response)
        }
    }

    // MARK: - Command Handlers

    private func handleListWindows() async -> MCPListWindowsResponse {
        let windows = await MainActor.run {
            windowProvider.allWindowContexts().map { context in
                MCPWindowInfo(
                    identifier: context.identifier,
                    displayName: context.displayName,
                    isKeyWindow: context.isKeyWindow,
                    selectedTypeName: context.selectedRuntimeObject?.displayName,
                    selectedTypeImagePath: context.selectedRuntimeObject?.imagePath
                )
            }
        }
        return MCPListWindowsResponse(windows: windows)
    }

    private func handleSelectedType(_ request: MCPSelectedTypeRequest) async -> MCPSelectedTypeResponse {
        guard let runtimeObject = await MainActor.run(body: {
            windowProvider.windowContext(forIdentifier: request.windowIdentifier)?.selectedRuntimeObject
        }) else {
            return MCPSelectedTypeResponse(
                imagePath: nil,
                typeName: nil,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil
            )
        }

        let engine = await runtimeEngine(forWindowIdentifier: request.windowIdentifier)
        let options = generationOptions()

        do {
            let interface = try await engine.interface(for: runtimeObject, options: options)
            return MCPSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: interface?.interfaceString.string
            )
        } catch {
            logger.error("Failed to generate interface for selected type: \(error)")
            return MCPSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: nil
            )
        }
    }

    private func handleTypeInterface(_ request: MCPTypeInterfaceRequest) async -> MCPTypeInterfaceResponse {
        let engine = await runtimeEngine(forWindowIdentifier: request.windowIdentifier)
        let options = generationOptions()

        do {
            let objects = try await engine.objects(in: request.imagePath)
            guard let runtimeObject = findObject(named: request.typeName, in: objects) else {
                return MCPTypeInterfaceResponse(
                    imagePath: request.imagePath,
                    typeName: request.typeName,
                    displayName: nil,
                    typeKind: nil,
                    interfaceText: nil,
                    error: "Type '\(request.typeName)' not found in image '\(request.imagePath)'"
                )
            }

            let interface = try await engine.interface(for: runtimeObject, options: options)
            return MCPTypeInterfaceResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: interface?.interfaceString.string,
                error: nil
            )
        } catch {
            return MCPTypeInterfaceResponse(
                imagePath: request.imagePath,
                typeName: request.typeName,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil,
                error: error.localizedDescription
            )
        }
    }

    private func handleListTypes(_ request: MCPListTypesRequest) async -> MCPListTypesResponse {
        let engine = await runtimeEngine(forWindowIdentifier: request.windowIdentifier)

        do {
            let objects = try await engine.objects(in: request.imagePath)
            let types = flattenObjects(objects).map { obj in
                MCPRuntimeTypeInfo(
                    name: obj.name,
                    displayName: obj.displayName,
                    kind: obj.kind.description,
                    imagePath: obj.imagePath
                )
            }
            return MCPListTypesResponse(types: types, error: nil)
        } catch {
            return MCPListTypesResponse(types: [], error: error.localizedDescription)
        }
    }

    private func handleSearchTypes(_ request: MCPSearchTypesRequest) async -> MCPSearchTypesResponse {
        let engine = await runtimeEngine(forWindowIdentifier: request.windowIdentifier)
        let queryLowercased = request.query.lowercased()

        do {
            var results: [MCPRuntimeTypeInfo] = []

            if let imagePath = request.imagePath {
                // Search within a specific image
                let objects = try await engine.objects(in: imagePath)
                let flattened = flattenObjects(objects)
                for obj in flattened {
                    if obj.name.lowercased().contains(queryLowercased) || obj.displayName.lowercased().contains(queryLowercased) {
                        results.append(MCPRuntimeTypeInfo(
                            name: obj.name,
                            displayName: obj.displayName,
                            kind: obj.kind.description,
                            imagePath: obj.imagePath
                        ))
                    }
                }
            } else {
                // Search across all loaded images
                let imageList = await engine.imageList
                for image in imageList {
                    do {
                        let objects = try await engine.objects(in: image)
                        let flattened = flattenObjects(objects)
                        for obj in flattened {
                            if obj.name.lowercased().contains(queryLowercased) || obj.displayName.lowercased().contains(queryLowercased) {
                                results.append(MCPRuntimeTypeInfo(
                                    name: obj.name,
                                    displayName: obj.displayName,
                                    kind: obj.kind.description,
                                    imagePath: obj.imagePath
                                ))
                            }
                        }
                    } catch {
                        logger.warning("Failed to load objects from image \(image): \(error)")
                        continue
                    }
                }
            }

            return MCPSearchTypesResponse(types: results, error: nil)
        } catch {
            return MCPSearchTypesResponse(types: [], error: error.localizedDescription)
        }
    }

    private func handleGrepTypeInterface(_ request: MCPGrepTypeInterfaceRequest) async -> MCPGrepTypeInterfaceResponse {
        let engine = await runtimeEngine(forWindowIdentifier: request.windowIdentifier)
        let options = generationOptions()
        let patternLowercased = request.pattern.lowercased()

        do {
            let objects = try await engine.objects(in: request.imagePath)
            let flattened = flattenObjects(objects)
            var matches: [MCPGrepMatch] = []

            for obj in flattened {
                do {
                    let interface = try await engine.interface(for: obj, options: options)
                    guard let text = interface?.interfaceString.string else { continue }

                    let matchingLines = text.components(separatedBy: .newlines).filter {
                        $0.lowercased().contains(patternLowercased)
                    }

                    if !matchingLines.isEmpty {
                        matches.append(MCPGrepMatch(
                            typeName: obj.name,
                            kind: obj.kind.description,
                            matchingLines: matchingLines
                        ))
                    }
                } catch {
                    logger.warning("Failed to generate interface for \(obj.name): \(error)")
                    continue
                }
            }

            return MCPGrepTypeInterfaceResponse(matches: matches, error: nil)
        } catch {
            return MCPGrepTypeInterfaceResponse(matches: [], error: error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func runtimeEngine(forWindowIdentifier identifier: String) async -> RuntimeEngine {
        await MainActor.run {
            windowProvider.windowContext(forIdentifier: identifier)?.runtimeEngine ?? .shared
        }
    }

    private func generationOptions() -> RuntimeObjectInterface.GenerationOptions {
        var options = appDefaults.options
        options.transformer = Settings.shared.transformer
        return options
    }

    // MARK: - Helpers

    private func flattenObjects(_ objects: [RuntimeObject]) -> [RuntimeObject] {
        var result: [RuntimeObject] = []
        for obj in objects {
            result.append(obj)
            if !obj.children.isEmpty {
                result.append(contentsOf: flattenObjects(obj.children))
            }
        }
        return result
    }

    private func findObject(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        for obj in objects {
            if obj.name == name || obj.displayName == name {
                return obj
            }
            if let found = findObject(named: name, in: obj.children) {
                return found
            }
        }
        return nil
    }
}

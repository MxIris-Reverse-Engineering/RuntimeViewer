import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

public actor MCPBridgeServer {
    private let windowProvider: MCPBridgeWindowProvider

    @Dependency(\.appDefaults)
    private var appDefaults

    public init(windowProvider: MCPBridgeWindowProvider) {
        self.windowProvider = windowProvider
    }

    // MARK: - Public Handle Methods

    public func handleListWindows() async -> MCPListWindowsResponse {
        let windows = await windowProvider.allWindowContexts().map { context in
            MCPWindowInfo(
                identifier: context.identifier,
                displayName: context.displayName,
                isKeyWindow: context.isKeyWindow,
                selectedTypeName: context.selectedRuntimeObject?.displayName,
                selectedTypeImagePath: context.selectedRuntimeObject?.imagePath
            )
        }

        return MCPListWindowsResponse(windows: windows)
    }

    public func handleSelectedType(_ request: MCPSelectedTypeRequest) async -> MCPSelectedTypeResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        guard let runtimeObject = context?.selectedRuntimeObject else {
            return MCPSelectedTypeResponse(
                imagePath: nil,
                typeName: nil,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil
            )
        }

        let engine = context?.runtimeEngine ?? .local
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

    public func handleTypeInterface(_ request: MCPTypeInterfaceRequest) async -> MCPTypeInterfaceResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        let engine = context?.runtimeEngine ?? .local
        let options = generationOptions()
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, selectedImagePath: context?.selectedImageNode?.path, engine: engine)

        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                if let runtimeObject = findObject(named: request.typeName, in: objects) {
                    let interface = try await engine.interface(for: runtimeObject, options: options)
                    return MCPTypeInterfaceResponse(
                        imagePath: runtimeObject.imagePath,
                        typeName: runtimeObject.name,
                        displayName: runtimeObject.displayName,
                        typeKind: runtimeObject.kind.description,
                        interfaceText: interface?.interfaceString.string,
                        error: nil
                    )
                }
            } catch {
                logger.warning("Failed to load objects from image \(imagePath): \(error)")
                continue
            }
        }

        let searchScope = request.imagePath ?? "all loaded images"
        return MCPTypeInterfaceResponse(
            imagePath: request.imagePath,
            typeName: request.typeName,
            displayName: nil,
            typeKind: nil,
            interfaceText: nil,
            error: "Type '\(request.typeName)' not found in \(searchScope)"
        )
    }

    public func handleListTypes(_ request: MCPListTypesRequest) async -> MCPListTypesResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        let engine = context?.runtimeEngine ?? .local
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, selectedImagePath: context?.selectedImageNode?.path, engine: engine)

        var allTypes: [MCPRuntimeTypeInfo] = []
        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                let types = flattenObjects(objects).map { MCPRuntimeTypeInfo(from: $0) }
                allTypes.append(contentsOf: types)
            } catch {
                logger.warning("Failed to load objects from image \(imagePath): \(error)")
                continue
            }
        }
        return MCPListTypesResponse(types: allTypes, error: nil)
    }

    public func handleSearchTypes(_ request: MCPSearchTypesRequest) async -> MCPSearchTypesResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        let engine = context?.runtimeEngine ?? .local
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, selectedImagePath: context?.selectedImageNode?.path, engine: engine)
        let queryLowercased = request.query.lowercased()

        var results: [MCPRuntimeTypeInfo] = []
        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                let flattened = flattenObjects(objects)
                for obj in flattened {
                    if obj.name.lowercased().contains(queryLowercased) || obj.displayName.lowercased().contains(queryLowercased) {
                        results.append(MCPRuntimeTypeInfo(from: obj))
                    }
                }
            } catch {
                logger.warning("Failed to load objects from image \(imagePath): \(error)")
                continue
            }
        }
        return MCPSearchTypesResponse(types: results, error: nil)
    }

    public func handleGrepTypeInterface(_ request: MCPGrepTypeInterfaceRequest) async -> MCPGrepTypeInterfaceResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        let engine = context?.runtimeEngine ?? .local
        let options = generationOptions()
        let patternLowercased = request.pattern.lowercased()

        // Note: grep does not fall back to selectedImageNode, only explicit imagePath or all loaded images
        let imagePaths: Set<String>
        if let imagePath = request.imagePath {
            imagePaths = [imagePath]
        } else {
            imagePaths = await engine.loadedImagePaths
        }

        var matches: [MCPGrepMatch] = []

        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                let flattened = flattenObjects(objects)

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
            } catch {
                logger.warning("Failed to load objects from image \(imagePath): \(error)")
                continue
            }
        }

        return MCPGrepTypeInterfaceResponse(matches: matches, error: nil)
    }

    public func handleMemberAddresses(_ request: MCPMemberAddressesRequest) async -> MCPMemberAddressesResponse {
        let context = await windowProvider.windowContext(forIdentifier: request.windowIdentifier)
        let engine = context?.runtimeEngine ?? .local
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, selectedImagePath: context?.selectedImageNode?.path, engine: engine)

        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                if let runtimeObject = findObject(named: request.typeName, in: objects) {
                    let members = try await engine.memberAddresses(for: runtimeObject, memberName: request.memberName)
                    return MCPMemberAddressesResponse(typeName: runtimeObject.displayName, members: members, error: nil)
                }
            } catch {
                logger.warning("Failed to load objects from image \(imagePath): \(error)")
                continue
            }
        }

        let searchScope = request.imagePath ?? "all loaded images"
        return MCPMemberAddressesResponse(
            typeName: request.typeName,
            members: [],
            error: "Type '\(request.typeName)' not found in \(searchScope)"
        )
    }

    // MARK: - Private Helpers

    private func resolveImagePaths(
        requestImagePath: String?,
        selectedImagePath: String?,
        engine: RuntimeEngine
    ) async -> Set<String> {
        if let imagePath = requestImagePath ?? selectedImagePath {
            return [imagePath]
        }
        return await engine.loadedImagePaths
    }

    private func generationOptions() -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions.mcp
        options.transformer = Settings.shared.transformer
        return options
    }

    private func flattenObjects(_ objects: [RuntimeObject]) -> [RuntimeObject] {
        var result: [RuntimeObject] = []
        func collect(_ objects: [RuntimeObject]) {
            for obj in objects {
                result.append(obj)
                if !obj.children.isEmpty {
                    collect(obj.children)
                }
            }
        }
        collect(objects)
        return result
    }

    private func findObject(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        for object in objects {
            if object.name == name || object.displayName == name {
                return object
            }
            if let found = findObject(named: name, in: object.children) {
                return found
            }
        }
        return nil
    }
}

import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

public actor MCPBridgeServer {
    private let documentProvider: MCPBridgeDocumentProvider
    private var objectsLoadedPaths: Set<String> = []

    @Dependency(\.settings)
    private var settings

    public init(documentProvider: MCPBridgeDocumentProvider) {
        self.documentProvider = documentProvider
    }

    // MARK: - Public Handle Methods

    public func handleListWindows() async -> MCPListWindowsResponse {
        let windows = await documentProvider.allDocumentContexts().map { context in
            MCPWindowInfo(
                identifier: context.identifier,
                displayName: context.displayName,
                isKeyWindow: context.isKeyWindow,
                selectedTypeName: context.selectedRuntimeObject?.displayName,
                selectedTypeImagePath: context.selectedRuntimeObject?.imagePath,
                selectedTypeImageName: context.selectedRuntimeObject?.imageName
            )
        }

        return MCPListWindowsResponse(windows: windows)
    }

    public func handleSelectedType(_ request: MCPSelectedTypeRequest) async throws -> MCPSelectedTypeResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        guard let runtimeObject = context.selectedRuntimeObject else {
            return MCPSelectedTypeResponse(
                imagePath: nil,
                imageName: nil,
                typeName: nil,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil
            )
        }

        let engine = context.runtimeEngine
        let options = generationOptions()

        do {
            let interface = try await engine.interface(for: runtimeObject, options: options)
            return MCPSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                imageName: runtimeObject.imageName,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: interface?.interfaceString.string
            )
        } catch {
            logger.error("Failed to generate interface for selected type: \(error)")
            return MCPSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                imageName: runtimeObject.imageName,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: nil
            )
        }
    }

    public func handleTypeInterface(_ request: MCPTypeInterfaceRequest) async throws -> MCPTypeInterfaceResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let options = generationOptions()
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, requestImageName: request.imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                if let runtimeObject = findObject(named: request.typeName, in: objects) {
                    let interface = try await engine.interface(for: runtimeObject, options: options)
                    return MCPTypeInterfaceResponse(
                        imagePath: runtimeObject.imagePath,
                        imageName: runtimeObject.imageName,
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

        let searchScope = request.imagePath ?? request.imageName ?? "all loaded images"
        return MCPTypeInterfaceResponse(
            imagePath: request.imagePath,
            imageName: request.imageName,
            typeName: request.typeName,
            displayName: nil,
            typeKind: nil,
            interfaceText: nil,
            error: "Type '\(request.typeName)' not found in \(searchScope)"
        )
    }

    public func handleListTypes(_ request: MCPListTypesRequest) async throws -> MCPListTypesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, requestImageName: request.imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        let allTypes = await withTaskGroup(of: [MCPRuntimeTypeInfo].self) { group in
            for imagePath in imagePaths {
                group.addTask {
                    do {
                        let objects = try await engine.objects(in: imagePath)
                        return self.flattenObjects(objects).map { MCPRuntimeTypeInfo(from: $0) }
                    } catch {
                        logger.warning("Failed to load objects from image \(imagePath): \(error)")
                        return []
                    }
                }
            }
            var result: [MCPRuntimeTypeInfo] = []
            for await types in group {
                result.append(contentsOf: types)
            }
            return result
        }
        return MCPListTypesResponse(types: allTypes, error: nil)
    }

    public func handleSearchTypes(_ request: MCPSearchTypesRequest) async throws -> MCPSearchTypesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, requestImageName: request.imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)
        let queryLowercased = request.query.lowercased()

        let results = await withTaskGroup(of: [MCPRuntimeTypeInfo].self) { group in
            for imagePath in imagePaths {
                group.addTask {
                    do {
                        let objects = try await engine.objects(in: imagePath)
                        return self.flattenObjects(objects).compactMap { obj -> MCPRuntimeTypeInfo? in
                            guard obj.name.lowercased().contains(queryLowercased) || obj.displayName.lowercased().contains(queryLowercased) else { return nil }
                            return MCPRuntimeTypeInfo(from: obj)
                        }
                    } catch {
                        logger.warning("Failed to load objects from image \(imagePath): \(error)")
                        return []
                    }
                }
            }
            var result: [MCPRuntimeTypeInfo] = []
            for await matches in group {
                result.append(contentsOf: matches)
            }
            return result
        }
        return MCPSearchTypesResponse(types: results, error: nil)
    }

    public func handleGrepTypeInterface(_ request: MCPGrepTypeInterfaceRequest) async throws -> MCPGrepTypeInterfaceResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let options = generationOptions()
        let patternLowercased = request.pattern.lowercased()

        // Note: grep does not fall back to selectedImageNode, only explicit imagePath/imageName or all loaded images
        let imagePaths: Set<String>
        if let imagePath = request.imagePath {
            await ensureImageLoaded(at: imagePath, engine: engine)
            imagePaths = [imagePath]
        } else if let imageName = request.imageName {
            var paths = await resolveImageName(imageName, engine: engine)
            if paths.isEmpty {
                await ensureImageLoaded(at: imageName, engine: engine)
                paths = await resolveImageName(imageName, engine: engine)
            }
            imagePaths = paths
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

    public func handleListImages(_ request: MCPListImagesRequest) async throws -> MCPListImagesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await engine.imageList
        return MCPListImagesResponse(imagePaths: imagePaths.sorted())
    }

    public func handleSearchImages(_ request: MCPSearchImagesRequest) async throws -> MCPSearchImagesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await engine.imageList
        let queryLowercased = request.query.lowercased()
        let matched = imagePaths.filter { $0.lowercased().contains(queryLowercased) }.sorted()
        return MCPSearchImagesResponse(imagePaths: matched)
    }

    public func handleLoadImage(_ request: MCPLoadImageRequest) async throws -> MCPLoadImageResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let loadedPaths = await engine.loadedImagePaths
        let imageAlreadyLoaded = loadedPaths.contains(request.imagePath)
        if !imageAlreadyLoaded {
            do {
                try await engine.loadImage(at: request.imagePath)
            } catch {
                logger.error("Failed to load image at \(request.imagePath): \(error)")
                return MCPLoadImageResponse(imagePath: request.imagePath, alreadyLoaded: false, objectsLoaded: false, error: "Failed to load image: \(error.localizedDescription)")
            }
        }
        var didLoadObjects = false
        if request.loadObjects && !objectsLoadedPaths.contains(request.imagePath) {
            do {
                _ = try await engine.objects(in: request.imagePath)
                objectsLoadedPaths.insert(request.imagePath)
                didLoadObjects = true
            } catch {
                logger.error("Failed to load objects from \(request.imagePath): \(error)")
                return MCPLoadImageResponse(imagePath: request.imagePath, alreadyLoaded: imageAlreadyLoaded, objectsLoaded: false, error: "Image loaded but failed to load objects: \(error.localizedDescription)")
            }
        }
        return MCPLoadImageResponse(imagePath: request.imagePath, alreadyLoaded: imageAlreadyLoaded, objectsLoaded: didLoadObjects || objectsLoadedPaths.contains(request.imagePath), error: nil)
    }

    public func handleIsImageLoaded(_ request: MCPIsImageLoadedRequest) async throws -> MCPIsImageLoadedResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let isLoaded = await engine.loadedImagePaths.contains(request.imagePath)
        return MCPIsImageLoadedResponse(imagePath: request.imagePath, isLoaded: isLoaded)
    }

    public func handleLoadObjects(_ request: MCPLoadObjectsRequest) async throws -> MCPLoadObjectsResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        if objectsLoadedPaths.contains(request.imagePath) {
            let objects = try await engine.objects(in: request.imagePath)
            return MCPLoadObjectsResponse(imagePath: request.imagePath, alreadyLoaded: true, objectCount: objects.count, error: nil)
        }
        do {
            let objects = try await engine.objects(in: request.imagePath)
            objectsLoadedPaths.insert(request.imagePath)
            return MCPLoadObjectsResponse(imagePath: request.imagePath, alreadyLoaded: false, objectCount: objects.count, error: nil)
        } catch {
            logger.error("Failed to load objects from \(request.imagePath): \(error)")
            return MCPLoadObjectsResponse(imagePath: request.imagePath, alreadyLoaded: false, objectCount: 0, error: "Failed to load objects: \(error.localizedDescription)")
        }
    }

    public func handleIsObjectsLoaded(_ request: MCPIsObjectsLoadedRequest) async throws -> MCPIsObjectsLoadedResponse {
        return MCPIsObjectsLoadedResponse(imagePath: request.imagePath, isLoaded: objectsLoadedPaths.contains(request.imagePath))
    }

    public func handleMemberAddresses(_ request: MCPMemberAddressesRequest) async throws -> MCPMemberAddressesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: request.windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await resolveImagePaths(requestImagePath: request.imagePath, requestImageName: request.imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        for imagePath in imagePaths {
            do {
                let objects = try await engine.objects(in: imagePath)
                if let runtimeObject = findObject(named: request.typeName, in: objects) {
                    let members = try await engine.memberAddresses(for: runtimeObject, memberName: request.memberName)
                    return MCPMemberAddressesResponse(typeName: runtimeObject.displayName, members: members.map { MCPMemberAddressInfo(from: $0) }, error: nil)
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
        requestImageName: String?,
        selectedImagePath: String?,
        engine: RuntimeEngine
    ) async -> Set<String> {
        if let imagePath = requestImagePath {
            await ensureImageLoaded(at: imagePath, engine: engine)
            return [imagePath]
        }
        if let imageName = requestImageName {
            let paths = await resolveImageName(imageName, engine: engine)
            if !paths.isEmpty {
                return paths
            }
            // Image not currently loaded — try loading by name as a full path
            await ensureImageLoaded(at: imageName, engine: engine)
            return await resolveImageName(imageName, engine: engine)
        }
        if let selectedImagePath {
            return [selectedImagePath]
        }
        return await engine.loadedImagePaths
    }

    private func ensureImageLoaded(at path: String, engine: RuntimeEngine) async {
        let loadedPaths = await engine.loadedImagePaths
        guard !loadedPaths.contains(path) else { return }
        do {
            try await engine.loadImage(at: path)
            logger.info("Loaded image at path: \(path)")
        } catch {
            logger.warning("Failed to load image at path \(path): \(error)")
        }
    }

    private func resolveImageName(_ imageName: String, engine: RuntimeEngine) async -> Set<String> {
        let loadedPaths = await engine.loadedImagePaths
        let nameLowercased = imageName.lowercased()
        let matched = loadedPaths.filter { path in
            let lastComponent = (path as NSString).lastPathComponent
            let nameWithoutExtension = (lastComponent as NSString).deletingPathExtension
            return nameWithoutExtension.lowercased() == nameLowercased
        }
        if !matched.isEmpty {
            return matched
        }
        // Fallback: try substring match
        return loadedPaths.filter { path in
            let lastComponent = (path as NSString).lastPathComponent
            return lastComponent.lowercased().contains(nameLowercased)
        }
    }

    private func generationOptions() -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions.mcp
        options.transformer = settings.transformer
        return options
    }

    private nonisolated func flattenObjects(_ objects: [RuntimeObject]) -> [RuntimeObject] {
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

import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import SwiftMCP
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

// MARK: - Error

enum MCPBridgeError: LocalizedError {
    case noTypeSelected
    case typeNotFound(name: String, scope: String)
    case imageNotLoaded(path: String)
    case imageNotFound(name: String)
    case imageLoadFailed(path: String, reason: String)
    case noImagesLoaded
    case noMatchingImages(query: String)
    case noTypesFound(scope: String)
    case interfaceGenerationFailed(typeName: String, reason: String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTypeSelected:
            return "No type is currently selected in the specified window."
        case .typeNotFound(let name, let scope):
            return "Type '\(name)' not found in \(scope). Please verify the type name is correct, or use searchTypes to find available types."
        case .imageNotLoaded(let path):
            return "Image '\(path)' is not loaded. Please call loadImage with this imagePath first."
        case .imageNotFound(let name):
            return "No loaded image matches '\(name)'. Please call searchImages to find the correct image path, then call loadImage to load it."
        case .imageLoadFailed(let path, let reason):
            return "Failed to load image '\(path)': \(reason). The file may not exist or may not be a valid Mach-O binary."
        case .noImagesLoaded:
            return "No images are currently loaded. Please call loadImage to load an image first, or open a document in RuntimeViewer."
        case .noMatchingImages(let query):
            return "No images match '\(query)'. Please call listImages to see all available image paths, or verify the query string."
        case .noTypesFound(let scope):
            return "No types found in \(scope). The image may not contain any Objective-C or Swift types, or objects may not have been loaded yet — try calling loadObjects first."
        case .interfaceGenerationFailed(let typeName, let reason):
            return "Failed to generate interface for type '\(typeName)': \(reason)"
        case .operationFailed(let message):
            return message
        }
    }
}

// MARK: - Object Load Result

private enum ObjectLoadResult<T> {
    case success([T])
    case failure(path: String, error: String)
}

// MARK: - MCP Bridge Server

@MCPServer(name: "RuntimeViewer")
public actor MCPBridgeServer {
    private let documentProvider: MCPBridgeDocumentProvider
    private var objectsLoadedPaths: Set<String> = []

    @Dependency(\.settings)
    private var settings

    public init(documentProvider: MCPBridgeDocumentProvider) {
        self.documentProvider = documentProvider
    }

    // MARK: - Prompts

    /// Inspect a runtime type's full interface declaration.
    /// Guides you through finding and displaying the generated header for a specific type.
    /// - Parameter typeName: The name of the type to inspect (e.g. 'NSView', 'UIViewController')
    /// - Parameter imageName: Optional framework or image name to narrow the search (e.g. 'AppKit', 'UIKit')
    @MCPPrompt
    func inspectType(typeName: String, imageName: String? = nil) -> [PromptMessage] {
        var text = """
        Please inspect the runtime type "\(typeName)" using RuntimeViewer.

        Steps:
        1. Call listWindows to get a windowIdentifier.
        2. Call searchTypes with query: "\(typeName)"\(imageName.map { ", imageName: \"\($0)\"" } ?? "") to find the exact type.
        3. Call getTypeInterface with the exact typeName\(imageName.map { " and imageName: \"\($0)\"" } ?? "") to retrieve the full interface.
        4. Present the interface text and summarize key properties, methods, and protocols.
        """
        if imageName == nil {
            text += "\n\nIf the type is not found, try calling searchImages first to locate the correct framework."
        }
        return [PromptMessage(role: .user, content: .init(text: text))]
    }

    /// Explore all types in a framework or dynamic library.
    /// Guides you through loading and browsing the contents of an image.
    /// - Parameter frameworkName: The name of the framework to explore (e.g. 'AppKit', 'Foundation', 'SwiftUI')
    @MCPPrompt
    func exploreFramework(frameworkName: String) -> [PromptMessage] {
        let text = """
        Please explore the "\(frameworkName)" framework using RuntimeViewer.

        Steps:
        1. Call listWindows to get a windowIdentifier.
        2. Call searchImages with query: "\(frameworkName)" to find the full image path.
        3. Call loadImage with the imagePath and loadObjects: true.
        4. Call listTypes with the imageName: "\(frameworkName)" to see all types.
        5. Summarize the types by category (classes, protocols, structs, enums) and highlight the most important ones.
        """
        return [PromptMessage(role: .user, content: .init(text: text))]
    }

    /// Compare two runtime types side by side.
    /// Guides you through retrieving and comparing the interfaces of two types.
    /// - Parameter firstType: The first type name to compare
    /// - Parameter secondType: The second type name to compare
    @MCPPrompt
    func compareTypes(firstType: String, secondType: String) -> [PromptMessage] {
        let text = """
        Please compare the runtime types "\(firstType)" and "\(secondType)" using RuntimeViewer.

        Steps:
        1. Call listWindows to get a windowIdentifier.
        2. Call searchTypes for each type to find their exact names and images.
        3. Call getTypeInterface for both types.
        4. Compare their interfaces: common protocols, similar methods, property differences, and inheritance hierarchies.
        """
        return [PromptMessage(role: .user, content: .init(text: text))]
    }

    // MARK: - Window Tools

    /// Lists all open RuntimeViewer document windows. Call this first — every other tool requires a windowIdentifier returned here.
    /// Each entry contains: identifier (stable per window session), display title, key-window flag,
    /// and the currently selected type's name, image path, and image name (if any).
    /// Returns an empty list when no documents are open; in that case, ask the user to launch RuntimeViewer and open a document.
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func listWindows() async -> MCPListWindowsResponse {
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

    // MARK: - Type Inspection Tools

    /// Returns the type currently selected in the sidebar of a RuntimeViewer window.
    /// Response includes: name, display name, kind, image path, and the full generated interface text.
    /// Throws an error if no type is selected.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func selectedType(windowIdentifier: String) async throws -> MCPSelectedTypeResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        guard let runtimeObject = context.selectedRuntimeObject else {
            throw MCPBridgeError.noTypeSelected
        }

        let engine = context.runtimeEngine
        let options = generationOptions()

        let interface: RuntimeObjectInterface?
        do {
            interface = try await engine.interface(for: runtimeObject, options: options)
        } catch {
            logger.error("Failed to generate interface for selected type '\(runtimeObject.displayName)': \(error)")
            throw MCPBridgeError.interfaceGenerationFailed(typeName: runtimeObject.displayName, reason: error.localizedDescription)
        }

        return MCPSelectedTypeResponse(
            imagePath: runtimeObject.imagePath,
            imageName: runtimeObject.imageName,
            typeName: runtimeObject.name,
            displayName: runtimeObject.displayName,
            typeKind: runtimeObject.kind.description,
            interfaceText: interface?.interfaceString.string
        )
    }

    /// Retrieves the full generated interface declaration for a type by exact name match.
    /// Providing imagePath or imageName restricts the search and is significantly faster;
    /// omitting both searches all previously loaded images.
    /// Use searchTypes first if you are unsure of the exact type name or image.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter typeName: Exact type name — matches against both internal name and display name
    /// - Parameter imagePath: Full path of the image (framework/dylib) containing the type. Mutually exclusive with imageName.
    /// - Parameter imageName: Short name of the image without path or extension (e.g. 'AppKit'). Case-insensitive. Mutually exclusive with imagePath.
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func typeInterface(windowIdentifier: String, typeName: String, imagePath: String? = nil, imageName: String? = nil) async throws -> MCPTypeInterfaceResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let options = generationOptions()
        let resolvedPaths = try await resolveImagePaths(requestImagePath: imagePath, requestImageName: imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        var objectLoadErrors: [(path: String, error: String)] = []

        for path in resolvedPaths {
            do {
                let objects = try await engine.objects(in: path)
                if let runtimeObject = findObject(named: typeName, in: objects) {
                    let interface: RuntimeObjectInterface?
                    do {
                        interface = try await engine.interface(for: runtimeObject, options: options)
                    } catch {
                        throw MCPBridgeError.interfaceGenerationFailed(typeName: runtimeObject.displayName, reason: error.localizedDescription)
                    }
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
            } catch let error as MCPBridgeError {
                throw error
            } catch {
                logger.warning("Failed to load objects from image \(path): \(error)")
                objectLoadErrors.append((path: path, error: error.localizedDescription))
                continue
            }
        }

        // If all paths failed to load objects, report that instead of "type not found"
        if !objectLoadErrors.isEmpty && objectLoadErrors.count == resolvedPaths.count {
            let details = objectLoadErrors.map { "'\($0.path)': \($0.error)" }.joined(separator: "; ")
            throw MCPBridgeError.operationFailed("Failed to load objects from all resolved images. Details: \(details). Try calling loadObjects for the target image first.")
        }

        throw MCPBridgeError.typeNotFound(name: typeName, scope: imagePath ?? imageName ?? "all loaded images")
    }

    /// Lists all runtime types in an image.
    /// WARNING: omitting both imagePath and imageName enumerates every type across all loaded images —
    /// this can produce an extremely large response. Always provide imagePath or imageName when possible.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter imagePath: Full path of the image to list types from. Mutually exclusive with imageName.
    /// - Parameter imageName: Short name of the image without path or extension. Case-insensitive. Mutually exclusive with imagePath.
    @MCPTool(naming: .pascalCase, hints: [.idempotent])
    func listTypes(windowIdentifier: String, imagePath: String? = nil, imageName: String? = nil) async throws -> MCPListTypesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let resolvedPaths = try await resolveImagePaths(requestImagePath: imagePath, requestImageName: imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        var objectLoadErrors: [(path: String, error: String)] = []

        let allTypes = await withTaskGroup(of: ObjectLoadResult<MCPRuntimeTypeInfo>.self) { group in
            for path in resolvedPaths {
                group.addTask {
                    do {
                        let objects = try await engine.objects(in: path)
                        return .success(self.flattenObjects(objects).map { MCPRuntimeTypeInfo(from: $0) })
                    } catch {
                        logger.warning("Failed to load objects from image \(path): \(error)")
                        return .failure(path: path, error: error.localizedDescription)
                    }
                }
            }
            var result: [MCPRuntimeTypeInfo] = []
            for await taskResult in group {
                switch taskResult {
                case .success(let types):
                    result.append(contentsOf: types)
                case .failure(let path, let error):
                    objectLoadErrors.append((path: path, error: error))
                }
            }
            return result
        }

        // If all paths failed to load objects, report the errors
        if allTypes.isEmpty && !objectLoadErrors.isEmpty {
            let details = objectLoadErrors.map { "'\($0.path)': \($0.error)" }.joined(separator: "; ")
            throw MCPBridgeError.operationFailed("Failed to load objects from all resolved images. Details: \(details). Try calling loadObjects for the target image first.")
        }

        if allTypes.isEmpty {
            let scope = imagePath ?? imageName ?? "all loaded images"
            throw MCPBridgeError.noTypesFound(scope: scope)
        }

        return MCPListTypesResponse(types: allTypes, error: nil)
    }

    /// Searches for runtime types by name using case-insensitive substring matching.
    /// Returns each match with its display name, kind, full image path, and image name.
    /// This is the preferred way to locate a type when you do not know its exact name or image.
    /// Throws an error if the specified image is not loaded or if no types match the query.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter query: Case-insensitive substring to match against type names
    /// - Parameter imagePath: Restrict search to a specific image path. Mutually exclusive with imageName.
    /// - Parameter imageName: Restrict search to images matching this short name. Case-insensitive. Mutually exclusive with imagePath.
    @MCPTool(naming: .pascalCase, hints: [.idempotent])
    func searchTypes(windowIdentifier: String, query: String, imagePath: String? = nil, imageName: String? = nil) async throws -> MCPSearchTypesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let resolvedPaths = try await resolveImagePaths(requestImagePath: imagePath, requestImageName: imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        let queryLowercased = query.lowercased()
        var objectLoadErrors: [(path: String, error: String)] = []

        let results = await withTaskGroup(of: ObjectLoadResult<MCPRuntimeTypeInfo>.self) { group in
            for path in resolvedPaths {
                group.addTask {
                    do {
                        let objects = try await engine.objects(in: path)
                        return .success(self.flattenObjects(objects).compactMap { obj -> MCPRuntimeTypeInfo? in
                            guard obj.name.lowercased().contains(queryLowercased) || obj.displayName.lowercased().contains(queryLowercased) else { return nil }
                            return MCPRuntimeTypeInfo(from: obj)
                        })
                    } catch {
                        logger.warning("Failed to load objects from image \(path): \(error)")
                        return .failure(path: path, error: error.localizedDescription)
                    }
                }
            }
            var result: [MCPRuntimeTypeInfo] = []
            for await taskResult in group {
                switch taskResult {
                case .success(let types):
                    result.append(contentsOf: types)
                case .failure(let path, let error):
                    objectLoadErrors.append((path: path, error: error))
                }
            }
            return result
        }

        // If all paths failed to load objects, report the errors
        if results.isEmpty && !objectLoadErrors.isEmpty {
            let details = objectLoadErrors.map { "'\($0.path)': \($0.error)" }.joined(separator: "; ")
            throw MCPBridgeError.operationFailed("Failed to load objects from all resolved images. Details: \(details). Try calling loadObjects for the target image first.")
        }

        if results.isEmpty {
            let scope = imagePath ?? imageName ?? "all loaded images"
            throw MCPBridgeError.typeNotFound(name: query, scope: scope)
        }

        return MCPSearchTypesResponse(types: results, error: nil)
    }

    /// Searches for lines matching a pattern within generated type interfaces.
    /// Returns matching lines grouped by type. Useful for finding method signatures, property declarations, etc.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter pattern: Case-insensitive substring to match against interface text lines
    /// - Parameter imagePath: Restrict search to a specific image path. Mutually exclusive with imageName.
    /// - Parameter imageName: Restrict search to images matching this short name. Case-insensitive. Mutually exclusive with imagePath.
//    @MCPTool
//    func grepTypeInterface(windowIdentifier: String, pattern: String, imagePath: String? = nil, imageName: String? = nil) async throws -> MCPGrepTypeInterfaceResponse {
//        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
//        let engine = context.runtimeEngine
//        let options = generationOptions()
//        let patternLowercased = pattern.lowercased()
//
//        // Note: grep does not fall back to selectedImageNode, only explicit imagePath/imageName or all loaded images
//        let resolvedPaths: Set<String>
//        if let imagePath {
//            await ensureImageLoaded(at: imagePath, engine: engine)
//            resolvedPaths = [imagePath]
//        } else if let imageName {
//            var paths = await resolveImageName(imageName, engine: engine)
//            if paths.isEmpty {
//                await ensureImageLoaded(at: imageName, engine: engine)
//                paths = await resolveImageName(imageName, engine: engine)
//            }
//            resolvedPaths = paths
//        } else {
//            resolvedPaths = await engine.loadedImagePaths
//        }
//
//        var matches: [MCPGrepMatch] = []
//
//        for path in resolvedPaths {
//            do {
//                let objects = try await engine.objects(in: path)
//                let flattened = flattenObjects(objects)
//
//                for obj in flattened {
//                    do {
//                        let interface = try await engine.interface(for: obj, options: options)
//                        guard let text = interface?.interfaceString.string else { continue }
//
//                        let matchingLines = text.components(separatedBy: .newlines).filter {
//                            $0.lowercased().contains(patternLowercased)
//                        }
//
//                        if !matchingLines.isEmpty {
//                            matches.append(MCPGrepMatch(
//                                typeName: obj.name,
//                                kind: obj.kind.description,
//                                matchingLines: matchingLines
//                            ))
//                        }
//                    } catch {
//                        logger.warning("Failed to generate interface for \(obj.name): \(error)")
//                        continue
//                    }
//                }
//            } catch {
//                logger.warning("Failed to load objects from image \(path): \(error)")
//                continue
//            }
//        }
//
//        return MCPGrepTypeInterfaceResponse(matches: matches, error: nil)
//    }

    // MARK: - Image Tools

    /// Lists all image paths (frameworks, dylibs, executables) visible to the runtime.
    /// Returns the full file system path of every image registered in dyld.
    /// Use this to discover available images before querying types.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func listImages(windowIdentifier: String) async throws -> MCPListImagesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await engine.imageList
        return MCPListImagesResponse(imagePaths: imagePaths.sorted())
    }

    /// Searches all image paths by case-insensitive substring matching.
    /// Use this to find the correct imagePath before calling other tools.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter query: Case-insensitive substring to match against image paths
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func searchImages(windowIdentifier: String, query: String) async throws -> MCPSearchImagesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let imagePaths = await engine.imageList
        let queryLowercased = query.lowercased()
        let matched = imagePaths.filter { $0.lowercased().contains(queryLowercased) }.sorted()

        if matched.isEmpty {
            throw MCPBridgeError.noMatchingImages(query: query)
        }

        return MCPSearchImagesResponse(imagePaths: matched)
    }

    // MARK: - Member Address Tools

    /// Returns runtime memory addresses of a type's members. Supports both Swift and Objective-C types.
    /// Each entry includes: kind, demangled name, symbol name, and hex address.
    /// Useful for setting breakpoints, hooking functions, or correlating disassembly with source symbols.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter typeName: The name of the type to inspect
    /// - Parameter imagePath: Full path of the image containing the type. Mutually exclusive with imageName.
    /// - Parameter imageName: Short name of the image. Case-insensitive. Mutually exclusive with imagePath.
    /// - Parameter memberName: Filter to members whose name contains this string (case-insensitive).
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func memberAddresses(windowIdentifier: String, typeName: String, imagePath: String? = nil, imageName: String? = nil, memberName: String? = nil) async throws -> MCPMemberAddressesResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let resolvedPaths = try await resolveImagePaths(requestImagePath: imagePath, requestImageName: imageName, selectedImagePath: context.selectedImageNode?.path, engine: engine)

        var objectLoadErrors: [(path: String, error: String)] = []

        for path in resolvedPaths {
            do {
                let objects = try await engine.objects(in: path)
                if let runtimeObject = findObject(named: typeName, in: objects) {
                    let members = try await engine.memberAddresses(for: runtimeObject, memberName: memberName)
                    return MCPMemberAddressesResponse(typeName: runtimeObject.displayName, members: members.map { MCPMemberAddressInfo(from: $0) }, error: nil)
                }
            } catch {
                logger.warning("Failed to load objects from image \(path): \(error)")
                objectLoadErrors.append((path: path, error: error.localizedDescription))
                continue
            }
        }

        // If all paths failed to load objects, report that instead of "type not found"
        if !objectLoadErrors.isEmpty && objectLoadErrors.count == resolvedPaths.count {
            let details = objectLoadErrors.map { "'\($0.path)': \($0.error)" }.joined(separator: "; ")
            throw MCPBridgeError.operationFailed("Failed to load objects from all resolved images. Details: \(details). Try calling loadObjects for the target image first.")
        }

        throw MCPBridgeError.typeNotFound(name: typeName, scope: imagePath ?? imageName ?? "all loaded images")
    }

    // MARK: - Image Loading Tools

    /// Loads and parses an image (framework, dylib, executable) into RuntimeViewer.
    /// Set loadObjects to true to also enumerate runtime objects in a single call.
    /// Returns immediately if the image is already loaded.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter imagePath: Full file system path of the image to load
    /// - Parameter loadObjects: If true, also enumerate and cache runtime objects. Defaults to false.
    @MCPTool(naming: .pascalCase, hints: [.idempotent])
    func loadImage(windowIdentifier: String, imagePath: String, loadObjects: Bool = false) async throws -> MCPLoadImageResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let loadedPaths = await engine.loadedImagePaths
        let imageAlreadyLoaded = loadedPaths.contains(imagePath)
        if !imageAlreadyLoaded {
            do {
                try await engine.loadImage(at: imagePath)
            } catch {
                logger.error("Failed to load image at \(imagePath): \(error)")
                throw MCPBridgeError.operationFailed("Failed to load image: \(error.localizedDescription)")
            }
        }
        var didLoadObjects = false
        if loadObjects && !objectsLoadedPaths.contains(imagePath) {
            do {
                _ = try await engine.objects(in: imagePath)
                objectsLoadedPaths.insert(imagePath)
                didLoadObjects = true
            } catch {
                logger.error("Failed to load objects from \(imagePath): \(error)")
                throw MCPBridgeError.operationFailed("Image loaded but failed to load objects: \(error.localizedDescription)")
            }
        }
        return MCPLoadImageResponse(imagePath: imagePath, alreadyLoaded: imageAlreadyLoaded, objectsLoaded: didLoadObjects || objectsLoadedPaths.contains(imagePath), error: nil)
    }

    /// Checks whether an image has been loaded and parsed by RuntimeViewer.
    /// Use this to check before deciding whether to call loadImage.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter imagePath: Full file system path of the image to check
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func isImageLoaded(windowIdentifier: String, imagePath: String) async throws -> MCPIsImageLoadedResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        let isLoaded = try await engine.isImageLoaded(path: imagePath)
        return MCPIsImageLoadedResponse(imagePath: imagePath, isLoaded: isLoaded)
    }

    /// Enumerates and caches all runtime objects (types) from a loaded image.
    /// If the image is not yet loaded, it will be loaded automatically.
    /// Once loaded, objects are available for listTypes, searchTypes, getTypeInterface, etc.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter imagePath: Full file system path of the image to load objects from
    @MCPTool(naming: .pascalCase, hints: [.idempotent])
    func loadObjects(windowIdentifier: String, imagePath: String) async throws -> MCPLoadObjectsResponse {
        let context = try await documentProvider.documentContext(forIdentifier: windowIdentifier)
        let engine = context.runtimeEngine
        if objectsLoadedPaths.contains(imagePath) {
            let objects = try await engine.objects(in: imagePath)
            return MCPLoadObjectsResponse(imagePath: imagePath, alreadyLoaded: true, objectCount: objects.count, error: nil)
        }
        do {
            let objects = try await engine.objects(in: imagePath)
            objectsLoadedPaths.insert(imagePath)
            return MCPLoadObjectsResponse(imagePath: imagePath, alreadyLoaded: false, objectCount: objects.count, error: nil)
        } catch {
            logger.error("Failed to load objects from \(imagePath): \(error)")
            throw MCPBridgeError.operationFailed("Failed to load objects: \(error.localizedDescription)")
        }
    }

    /// Checks whether runtime objects have been enumerated for a given image.
    /// Use this to decide whether to call loadObjects before querying types.
    /// - Parameter windowIdentifier: The window identifier obtained from listWindows
    /// - Parameter imagePath: Full file system path of the image to check
    @MCPTool(naming: .pascalCase, hints: [.readOnly])
    func isObjectsLoaded(windowIdentifier: String, imagePath: String) async throws -> MCPIsObjectsLoadedResponse {
        MCPIsObjectsLoadedResponse(imagePath: imagePath, isLoaded: objectsLoadedPaths.contains(imagePath))
    }

    // MARK: - Private Helpers

    private func resolveImagePaths(
        requestImagePath: String?,
        requestImageName: String?,
        selectedImagePath: String?,
        engine: RuntimeEngine
    ) async throws -> Set<String> {
        if let imagePath = requestImagePath {
            let isLoaded: Bool
            do {
                isLoaded = try await engine.isImageLoaded(path: imagePath)
            } catch {
                throw MCPBridgeError.operationFailed("Failed to check image status for '\(imagePath)': \(error.localizedDescription)")
            }
            if !isLoaded {
                do {
                    try await engine.loadImage(at: imagePath)
                    logger.info("Auto-loaded image at path: \(imagePath)")
                } catch {
                    throw MCPBridgeError.imageLoadFailed(path: imagePath, reason: error.localizedDescription)
                }
            }
            return [imagePath]
        }
        if let imageName = requestImageName {
            // First check already-loaded images by short name
            let paths = await resolveImageName(imageName, engine: engine)
            if !paths.isEmpty {
                return paths
            }
            // Resolve full path from dyld image list
            let fullPath = await resolveImageNameFromImageList(imageName, engine: engine)
            if let fullPath {
                let isLoaded: Bool
                do {
                    isLoaded = try await engine.isImageLoaded(path: fullPath)
                } catch {
                    throw MCPBridgeError.operationFailed("Failed to check image status for '\(fullPath)': \(error.localizedDescription)")
                }
                if !isLoaded {
                    do {
                        try await engine.loadImage(at: fullPath)
                        logger.info("Auto-loaded image at path: \(fullPath)")
                    } catch {
                        throw MCPBridgeError.imageLoadFailed(path: fullPath, reason: error.localizedDescription)
                    }
                }
                return [fullPath]
            }
            // Not found in image list — last resort: try loading by name as a direct path
            do {
                try await engine.loadImage(at: imageName)
                logger.info("Auto-loaded image at path: \(imageName)")
            } catch {
                logger.info("Could not load '\(imageName)' as a direct path: \(error)")
            }
            let retryPaths = await resolveImageName(imageName, engine: engine)
            if retryPaths.isEmpty {
                throw MCPBridgeError.imageNotFound(name: imageName)
            }
            return retryPaths
        }
        if let selectedImagePath {
            return [selectedImagePath]
        }
        let loadedPaths = await engine.loadedImagePaths
        if loadedPaths.isEmpty {
            throw MCPBridgeError.noImagesLoaded
        }
        return loadedPaths
    }

    private func resolveImageNameFromImageList(_ imageName: String, engine: RuntimeEngine) async -> String? {
        let allImages = await engine.imageList
        let nameLowercased = imageName.lowercased()
        // Exact name match (without extension)
        if let match = allImages.first(where: { path in
            let lastComponent = (path as NSString).lastPathComponent
            let nameWithoutExtension = (lastComponent as NSString).deletingPathExtension
            return nameWithoutExtension.lowercased() == nameLowercased
        }) {
            return match
        }
        // Fallback: substring match
        return allImages.first(where: { path in
            let lastComponent = (path as NSString).lastPathComponent
            return lastComponent.lowercased().contains(nameLowercased)
        })
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

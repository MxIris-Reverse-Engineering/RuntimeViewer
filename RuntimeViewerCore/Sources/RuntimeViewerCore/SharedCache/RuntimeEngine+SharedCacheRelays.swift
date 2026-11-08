import Foundation

// Requests about one of an engine's own images that reach across images to
// answer — a reference to a type defined elsewhere, a superclass or a refined
// protocol in another image. Once the shared cache's images belong to their
// owners, the serving process no longer indexes them, so what it cannot
// resolve is handed on to the owners. A request about a borrowed image itself
// never comes here: `dispatch(_:)` sends it to the owner, whose own fallbacks
// see the whole shared cache.

extension RuntimeEngine {
    /// `interface(for:options:)` for an engine that borrows shared cache
    /// images, about an object of its own images or a reference by name.
    /// Four places are asked in turn, the first answer winning:
    ///
    /// 1. The serving process, for the object's own image only — the object
    ///    itself, or a reference its image defines.
    /// 2. For an Objective-C reference — by name alone, or as Swift imports
    ///    one — the image that defines it: the serving process's runtime says
    ///    which image that is without indexing anything, and when it is a
    ///    borrowed one its owner loads and indexes it, as a window on the
    ///    owner opening it would. Indexing it in the serving process is the
    ///    duplicate work borrowing exists to stop.
    /// 3. The owners, whose own lookups span the shared cache's types.
    /// 4. The serving process again, its lookups across its own images now
    ///    included: a reference to another of its own images.
    ///
    /// A serving process of an earlier release does not know the first ask's
    /// limit and looks the reference up already in step 1.
    func interfaceAcrossOwners(
        for object: RuntimeObject,
        options: RuntimeObjectInterface.GenerationOptions,
        participants: [RuntimeSharedCacheParticipant]
    ) async throws -> RuntimeObjectInterface? {
        var ownImageCommand = Self.interfaceCommand(for: object, options: options)
        ownImageCommand.resolvesReferencesAcrossImages = false
        if let interface = try await dispatchToServingProcess(ownImageCommand).interface {
            return interface
        }
        let command = Self.interfaceCommand(for: object, options: options)
        if let referencedObject = Self.objcReferencedObject(of: object),
           let definingImagePath = try? await dispatchToServingProcess(ImageNameOfObjectCommand(object: referencedObject)) {
            guard let owner = sharedCacheOwner(forImageAt: definingImagePath) else {
                // One of the serving process's own images defines it.
                return try await dispatchToServingProcess(command).interface
            }
            try await owner.indexBorrowedImageIfNeeded(at: definingImagePath)
            let definingObject = RuntimeObject(
                name: referencedObject.name,
                displayName: referencedObject.displayName,
                kind: referencedObject.kind,
                imagePath: definingImagePath,
                children: []
            )
            return try await owner.dispatchToServingProcess(Self.interfaceCommand(for: definingObject, options: options)).interface
        }
        for owner in participants.owners {
            if let interface = try? await owner.dispatch(command).interface {
                return interface
            }
        }
        return try await dispatchToServingProcess(command).interface
    }

    /// `superclassChain(for:)` for an engine that borrows shared cache
    /// images, about a class of its own images. The serving process walks the
    /// chain as far as its own images define it and names the levels above by
    /// their runtime names alone; the first such level an owner has indexed is
    /// resolved there, with its chain above it.
    func superclassChainAcrossOwners(
        for object: RuntimeObject,
        participants: [RuntimeSharedCacheParticipant]
    ) async throws -> [RuntimeRelationshipNode] {
        let chain = try await dispatchToServingProcess(SuperclassChainCommand(object: object))
        guard let unresolvedIndex = chain.firstIndex(where: { !$0.isResolved }) else { return chain }
        let unresolvedName = chain[unresolvedIndex].name
        guard let resolvedTree = await participants.ownersAncestorTrees(named: [unresolvedName])[unresolvedName],
              let owner = participants.owners.first(where: { $0.includesImage(resolvedTree.root.imagePath) }),
              let chainAbove = try? await owner.dispatch(SuperclassChainCommand(object: resolvedTree.root))
        else { return chain }
        return Array(chain[..<unresolvedIndex]) + [RuntimeRelationshipNode(object: resolvedTree.root)] + chainAbove
    }

    /// `refinedProtocolTree(for:)` for an engine that borrows shared cache
    /// images, about a protocol of its own images: every refined protocol the
    /// serving process could not resolve is resolved by an owner, with the
    /// protocols it refines in turn underneath.
    func refinedProtocolTreeAcrossOwners(
        for object: RuntimeObject,
        participants: [RuntimeSharedCacheParticipant]
    ) async throws -> [RuntimeRelationshipNode] {
        let tree = try await dispatchToServingProcess(RefinedProtocolTreeCommand(object: object))
        let unresolvedNames = tree.unresolvedNames
        guard !unresolvedNames.isEmpty else { return tree }
        return tree.resolving(await participants.ownersAncestorTrees(named: unresolvedNames))
    }

    /// Makes sure this engine — an owner — has the image at `imagePath`
    /// loaded and indexed, for a request a borrowing engine is about to hand
    /// it about one of the image's types.
    func indexBorrowedImageIfNeeded(at imagePath: String) async throws {
        guard try await !isImageIndexed(path: imagePath) else { return }
        if try await isImageLoaded(path: imagePath) {
            _ = try await objects(in: imagePath)
        } else {
            try await loadImage(at: imagePath)
        }
    }

    /// The Objective-C class or protocol `object` refers to by name — itself,
    /// when it is one with no image; the imported type, when it is a Swift
    /// reference to one — or `nil`.
    static func objcReferencedObject(of object: RuntimeObject) -> RuntimeObject? {
        switch object.kind {
        case .objc(.type(.class)), .objc(.type(.protocol)):
            return object.imagePath.isEmpty ? object : nil
        case .swift:
            guard let reference = objcReference(forSwiftMangledName: object.name) else { return nil }
            return RuntimeObject(name: reference.name, displayName: reference.name, kind: reference.kind, imagePath: "", children: [])
        default:
            return nil
        }
    }

    private static func interfaceCommand(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) -> InterfaceCommand {
        InterfaceCommand(object: object, options: options, acceptsColumnarInterfaceString: true)
    }
}

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
    /// their runtime names alone; the first such level is resolved by an
    /// owner — as a class, never as the protocol a class may share its name
    /// with, as `NSObject` does — with its chain above it.
    ///
    /// When no owner has indexed the image that defines that class, the
    /// serving process's runtime says which image it is, and the image's
    /// owner indexes it first, as `interfaceAcrossOwners` does for a
    /// reference: a Mac Catalyst class's chain ends at libobjc's `NSObject`
    /// even when nothing on "My Mac" has opened libobjc.
    func superclassChainAcrossOwners(
        for object: RuntimeObject,
        participants: [RuntimeSharedCacheParticipant]
    ) async throws -> [RuntimeRelationshipNode] {
        let chain = try await dispatchToServingProcess(SuperclassChainCommand(object: object))
        guard let unresolvedIndex = chain.firstIndex(where: { !$0.isResolved }) else { return chain }
        // Every level of a superclass chain is a class, whether or not a
        // serving process of an earlier release said so.
        let unresolvedSuperclass = RuntimeRelationshipNode.UnresolvedType(name: chain[unresolvedIndex].name, kind: .class)
        guard let superclass = await ownersClass(unresolvedSuperclass, participants: participants),
              let owner = participants.owners.first(where: { $0.includesImage(superclass.imagePath) }),
              let chainAbove = try? await owner.dispatch(SuperclassChainCommand(object: superclass))
        else { return chain }
        return Array(chain[..<unresolvedIndex]) + [RuntimeRelationshipNode(object: superclass)] + chainAbove
    }

    /// The class `unresolvedClass` names, from the owner that keeps the image
    /// defining it — indexed first when it is not yet — or `nil` when no
    /// owner can say.
    private func ownersClass(
        _ unresolvedClass: RuntimeRelationshipNode.UnresolvedType,
        participants: [RuntimeSharedCacheParticipant]
    ) async -> RuntimeObject? {
        if let tree = await participants.ownersAncestorTrees(for: [unresolvedClass])[unresolvedClass] {
            return tree.root
        }
        let referencedClass = RuntimeObject(
            name: unresolvedClass.name,
            displayName: unresolvedClass.name,
            kind: .objc(.type(.class)),
            imagePath: "",
            children: []
        )
        guard let definingImagePath = try? await dispatchToServingProcess(ImageNameOfObjectCommand(object: referencedClass)),
              let owner = sharedCacheOwner(forImageAt: definingImagePath)
        else { return nil }
        do {
            try await owner.indexBorrowedImageIfNeeded(at: definingImagePath)
        } catch {
            return nil
        }
        return await participants.ownersAncestorTrees(for: [unresolvedClass])[unresolvedClass]?.root
    }

    /// `refinedProtocolTree(for:)` for an engine that borrows shared cache
    /// images, about a protocol of its own images: every refined protocol the
    /// serving process could not resolve is resolved by an owner — as a
    /// protocol, never as a class of the same name — with the protocols it
    /// refines in turn underneath.
    func refinedProtocolTreeAcrossOwners(
        for object: RuntimeObject,
        participants: [RuntimeSharedCacheParticipant]
    ) async throws -> [RuntimeRelationshipNode] {
        let tree = try await dispatchToServingProcess(RefinedProtocolTreeCommand(object: object))
        // Every node of the tree is a protocol, whether or not a serving
        // process of an earlier release said so.
        let unresolvedTypes = tree.unresolvedTypes(assumingKind: .protocol)
        guard !unresolvedTypes.isEmpty else { return tree }
        return tree.resolving(await participants.ownersAncestorTrees(for: unresolvedTypes), assumingKind: .protocol)
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

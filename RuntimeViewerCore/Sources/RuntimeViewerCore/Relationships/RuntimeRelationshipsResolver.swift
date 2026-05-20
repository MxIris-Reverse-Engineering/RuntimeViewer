import Foundation
import OrderedCollections
import Demangling

/// Cross-image relationship resolver backing the Inspector's Relationships tab.
///
/// Given an inspectable `RuntimeObject`, computes its direct subclasses (for
/// classes) or conforming types (for protocols) by unioning per-image results
/// across every indexed Mach-O image.
///
/// Mirrors the `RuntimeObjCSection` / `RuntimeSwiftSection` split: per-image
/// extraction lives in those section actors, while this actor sits one level
/// up — alongside `RuntimeObjCSectionFactory` / `RuntimeSwiftSectionFactory` —
/// and owns the cross-image union. `RuntimeEngine.relationships(for:)` keeps
/// only the thin local/remote dispatch wrapper and delegates the actual work
/// here, so the engine file carries no relationship logic of its own.
actor RuntimeRelationshipsResolver {
    private let objcSectionFactory: RuntimeObjCSectionFactory

    private let swiftSectionFactory: RuntimeSwiftSectionFactory

    init(objcSectionFactory: RuntimeObjCSectionFactory, swiftSectionFactory: RuntimeSwiftSectionFactory) {
        self.objcSectionFactory = objcSectionFactory
        self.swiftSectionFactory = swiftSectionFactory
    }

    /// Cross-image relationships for an inspectable target:
    ///   - For classes: every direct subclass across all indexed images.
    ///   - For protocols: every conforming class across all indexed images.
    ///
    /// Returns `.empty` for kinds outside `{.objc(.type(.class)),
    /// .objc(.type(.protocol)), .swift(.type(.class)), .swift(.type(.protocol))}`
    /// (no throw). For supported kinds the result is the per-image union
    /// over `indexedImagePaths()` — every image with both an ObjC and a
    /// Swift section cached — so an image that has been loaded but not
    /// fully indexed contributes nothing.
    ///
    /// The target object's `imagePath` is the *defining* image. Conformers
    /// and subclasses may live in *any* indexed image, so we iterate every
    /// indexed image and union per-image results. Do not restrict to
    /// `object.imagePath` — that would miss cross-image conformers.
    ///
    /// The indexed-image set is derived from the section factories (see
    /// `indexedImagePaths()`), so the caller no longer threads the engine's
    /// `loadedImagePaths` through.
    func relationships(for object: RuntimeObject) async -> RuntimeRelationships {
        let isObjCClass = object.kind == .objc(.type(.class))
        let isObjCProtocol = object.kind == .objc(.type(.protocol))
        let isSwiftClass = object.kind == .swift(.type(.class))
        let isSwiftProtocol = object.kind == .swift(.type(.protocol))
        guard isObjCClass || isObjCProtocol || isSwiftClass || isSwiftProtocol else {
            return RuntimeRelationships.empty
        }
        let wantsSubclasses = isObjCClass || isSwiftClass
        let wantsConformers = isObjCProtocol || isSwiftProtocol

        // No synthetic ObjC<->Swift name bridging.
        //
        // For ObjC class/protocol targets, `object.name` is the raw ObjC
        // class/protocol name (the same string used as the key in
        // `RuntimeObjCInterfaceIndexer.classes`/`.protocols` and as the
        // `superclassByClassName` key in `RuntimeObjCInterfaceIndexer`).
        //
        // For Swift class targets, `object.name` is the mangled string
        // produced by `mangleAsString(typeName.node)`, which is the
        // same key space `subclassesBySuperclassMangledName` uses (we
        // round-trip superclass mangling through demangle + remangle
        // when building the table).
        //
        // Swift-derived ObjC subclasses are captured by the ObjC arm
        // through `__objc_classlist` (every `class Foo: NSObject`
        // emits a `class_t` record), so when both `objcKey` and
        // `swiftMangledKey` are set we skip the Swift arm to avoid
        // double-counting.
        let objcKey: String? = (isObjCClass || isObjCProtocol) ? object.name : nil
        let swiftMangledKey: String? = isSwiftClass ? object.name : nil

        var subclasses: OrderedSet<RuntimeObject> = []
        var conformers: OrderedSet<RuntimeObject> = []

        for imagePath in await indexedImagePaths() {
            if wantsSubclasses {
                if let objcKey {
                    if let objcSection = await objcSectionFactory.existingSection(for: imagePath) {
                        for reference in objcSection.objcIndexer.subclasses(of: objcKey) {
                            if let runtimeObject = await materializeRelationshipReference(reference) {
                                subclasses.append(runtimeObject)
                            }
                        }
                    }
                }
                if let swiftMangledKey {
                    if let swiftSection = await swiftSectionFactory.existingSection(for: imagePath) {
                        for childMangled in swiftSection.indexer.subclasses(of: swiftMangledKey) {
                            if let runtimeObject = await swiftSection.makeRuntimeObject(forMangledTypeName: childMangled) {
                                subclasses.append(runtimeObject)
                            }
                        }
                    }
                }
            }

            if wantsConformers {
                if isObjCProtocol {
                    if let objcSection = await objcSectionFactory.existingSection(for: imagePath) {
                        for reference in objcSection.objcIndexer.conformingClasses(toProtocol: object.name) {
                            if let runtimeObject = await materializeRelationshipReference(reference) {
                                conformers.append(runtimeObject)
                            }
                        }
                    }
                }
                if isSwiftProtocol {
                    if let swiftSection = await swiftSectionFactory.existingSection(for: imagePath) {
                        // Swift protocols are stored in the indexer under their demangled name
                        // (e.g. "Foundation.LocalizedError"); RuntimeObject.displayName carries
                        // exactly that string.
                        for mangled in swiftSection.indexer.conformingTypes(of: object.displayName) {
                            if let runtimeObject = await swiftSection.makeRuntimeObject(forMangledTypeName: mangled) {
                                conformers.append(runtimeObject)
                            }
                        }
                    }
                }
            }
        }

        let sortedSubclasses = Array(subclasses).sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        let sortedConformers = Array(conformers).sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return RuntimeRelationships(subclasses: sortedSubclasses, conformingTypes: sortedConformers)
    }

    /// Every image path with *both* an ObjC and a Swift section cached —
    /// the indexed-image universe a relationships query unions over. This
    /// is the set form of the per-path predicate
    /// `RuntimeEngine.isImageIndexed(path:)` evaluates: an image counts as
    /// indexed only once both sections exist.
    ///
    /// Both factories key their caches by the dyld-canonical path (every
    /// `section(for:)` call site patches the path first), so the two key
    /// sets intersect directly with no further normalization. Deriving the
    /// set here is what lets `relationships(for:)` drop its
    /// `loadedImagePaths` parameter — the resolver no longer depends on the
    /// engine to enumerate loaded images.
    private func indexedImagePaths() async -> Set<String> {
        let objcImagePaths = await objcSectionFactory.cachedImagePaths
        let swiftImagePaths = await swiftSectionFactory.cachedImagePaths
        return objcImagePaths.intersection(swiftImagePaths)
    }

    /// Materialize a per-image `ObjCClassReference` into the `RuntimeObject`
    /// the relationships query should surface. Bridged classes
    /// (`isSwiftStable == true`) are materialized as Swift `RuntimeObject`s
    /// (`kind == .swift(.type(.class))`) per AC6, by demangling the raw
    /// ObjC class name (`_TtC<n>module<m>name` form) and looking the
    /// corresponding Swift type definition up in the same image's Swift
    /// section. When that lookup fails (e.g. an `@objc(customName)` class
    /// whose raw name isn't a Swift mangling), the entry is dropped rather
    /// than fall back to `.objc(.type(.class))`.
    private func materializeRelationshipReference(_ reference: ObjCClassReference) async -> RuntimeObject? {
        if reference.isSwiftStable {
            // `demangleAsNode` / `mangleAsString` each ship a sync and an async
            // overload; the compiler picks the async one inside this `async`
            // context, so the `try?` needs an `await` for the implicit choice.
            if let node = try? await demangleAsNode(reference.className, isType: false),
               let swiftMangled = try? await mangleAsString(node),
               let swiftSection = await swiftSectionFactory.existingSection(for: reference.imagePath),
               let runtimeObject = await swiftSection.makeRuntimeObject(forMangledTypeName: swiftMangled) {
                return runtimeObject
            }
            return nil
        }
        guard let objcSection = await objcSectionFactory.existingSection(for: reference.imagePath) else { return nil }
        return await objcSection.makeRuntimeObject(forClassName: reference.className)
    }
}

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
        // `ObjCInterfaceIndexer.classes`/`.protocols` and as the
        // `superclassByClassName` key in `ObjCInterfaceIndexer`).
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

        // One query per side, not one per image.
        //
        // Each factory's `indexer` is the cross-image aggregate every per-image
        // indexer registers with, so a single call already spans every loaded
        // image. This used to walk `indexedImagePaths()` and ask each image
        // separately — hundreds of iterations and two actor hops apiece to get
        // "nothing" from almost all of them — because Evolution 0007 had removed
        // the ObjC aggregate. 0008 restores it and reads it from here.
        //
        // No `await` on the aggregate reads: both factories hold their `indexer`
        // as a `Sendable let`, which is implicitly nonisolated, and the query
        // methods are synchronous. So these cross no actor boundary at all —
        // which is the point, and is why the indexers guard themselves with
        // `@Mutex` rather than by being actors. The `await`s that remain are on
        // `materializeXxxReference`, which does hop, because it has to reach the
        // section actor that owns the image.
        if wantsSubclasses {
            if let objcKey {
                for reference in objcSectionFactory.indexer.subclasses(of: objcKey) {
                    if let runtimeObject = await materializeObjCReference(reference) {
                        subclasses.append(runtimeObject)
                    }
                }
            }
            if let swiftMangledKey {
                for reference in swiftSectionFactory.indexer.subclasses(of: swiftMangledKey) {
                    if let runtimeObject = await materializeSwiftReference(reference) {
                        subclasses.append(runtimeObject)
                    }
                }
            }
        }

        if wantsConformers {
            if isObjCProtocol {
                for reference in objcSectionFactory.indexer.conformingClasses(toProtocol: object.name) {
                    if let runtimeObject = await materializeObjCReference(reference) {
                        conformers.append(runtimeObject)
                    }
                }
            }
            if isSwiftProtocol {
                // Swift protocols are stored in the indexer under their demangled name
                // (e.g. "Foundation.LocalizedError"); RuntimeObject.displayName carries
                // exactly that string.
                for reference in swiftSectionFactory.indexer.conformingTypes(of: object.displayName) {
                    if let runtimeObject = await materializeSwiftReference(reference) {
                        conformers.append(runtimeObject)
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

    /// Materialize an `RuntimeObjCClassReference` into the `RuntimeObject`
    /// the relationships query should surface. Bridged classes
    /// (`isSwiftStable == true`) are materialized as Swift `RuntimeObject`s
    /// (`kind == .swift(.type(.class))`) per AC6, by demangling the raw
    /// ObjC class name (`_TtC<n>module<m>name` form) and looking the
    /// corresponding Swift type definition up in the same image's Swift
    /// section. When that lookup fails (e.g. an `@objc(customName)` class
    /// whose raw name isn't a Swift mangling), the entry is dropped rather
    /// than fall back to `.objc(.type(.class))`.
    ///
    /// Note the indexed-image predicate this no longer applies. The walk this
    /// replaced unioned over images with *both* sections cached, so an image
    /// holding only one contributed nothing; an aggregate query instead sees
    /// every indexer that registered. In practice `RuntimeEngine` creates the
    /// two sections together, so the sets coincide — and where they would not,
    /// dropping a relationship the user can see for a bookkeeping reason was
    /// never the intent. The equivalence snapshot covers the practical case.
    private func materializeObjCReference(_ reference: RuntimeObjCClassReference) async -> RuntimeObject? {
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

    /// Materialize a `RuntimeSwiftTypeReference` through the section for the
    /// image that named the type.
    ///
    /// Routing through `reference.imagePath` is what keeps the aggregate query
    /// honest: `RuntimeSwiftSection.makeRuntimeObject(forMangledTypeName:)`
    /// stamps its *own* `imagePath` onto the object it builds, so materializing
    /// a cross-image result through the wrong section would label the type with
    /// an image that does not define it. The per-image walk this replaced got
    /// that right implicitly by only ever asking an image about its own types;
    /// the reference now carries the image so it stays right explicitly.
    /// Mirrors `materializeObjCReference(_:)`.
    private func materializeSwiftReference(_ reference: RuntimeSwiftTypeReference) async -> RuntimeObject? {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: reference.imagePath) else { return nil }
        return await swiftSection.makeRuntimeObject(forMangledTypeName: reference.mangledName)
    }
}

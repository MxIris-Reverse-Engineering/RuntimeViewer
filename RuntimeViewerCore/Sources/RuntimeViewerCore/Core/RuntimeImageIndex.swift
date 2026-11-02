import Foundation
import MachOKit

/// An engine's parsed images: its catalog, the two section factories over the
/// catalog's images and the two relationship resolvers over the factories —
/// all built for one way of reading an image, and handed to the engine through
/// the protocols it holds them by.
///
/// The only place the five are put together, so an engine cannot end up with
/// a factory over one catalog and a resolver over another.
struct RuntimeImageIndex: Sendable {
    let catalog: any RuntimeImageCatalog

    let objcSectionFactory: any RuntimeObjCSectionProviding

    let swiftSectionFactory: any RuntimeSwiftSectionProviding

    let relationshipsResolver: any RuntimeRelationshipsResolving

    let typeRelationshipsResolver: any RuntimeTypeRelationshipsResolving

    /// `placeholderImage` stands behind the factories' aggregate indexers,
    /// which parse no image of their own.
    init<Catalog: RuntimeImageCatalog>(catalog: Catalog, placeholderImage: Catalog.MachO) {
        let objcSectionFactory = RuntimeObjCSectionFactory<Catalog.MachO>(catalog: catalog, placeholderImage: placeholderImage)
        let swiftSectionFactory = RuntimeSwiftSectionFactory<Catalog.MachO>(catalog: catalog, placeholderImage: placeholderImage)
        let relationshipsResolver = RuntimeRelationshipsResolver(objcSectionFactory: objcSectionFactory, swiftSectionFactory: swiftSectionFactory)
        self.catalog = catalog
        self.objcSectionFactory = objcSectionFactory
        self.swiftSectionFactory = swiftSectionFactory
        self.relationshipsResolver = relationshipsResolver
        self.typeRelationshipsResolver = RuntimeTypeRelationshipsResolver(
            objcSectionFactory: objcSectionFactory,
            swiftSectionFactory: swiftSectionFactory,
            relationshipsResolver: relationshipsResolver,
        )
    }

    /// The images dyld loaded into this process.
    static func process() -> RuntimeImageIndex {
        RuntimeImageIndex(catalog: RuntimeProcessImageCatalog(), placeholderImage: .current())
    }
}

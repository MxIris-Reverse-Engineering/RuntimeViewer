import Foundation
import FoundationToolbox
import Semantic

/// What the store needs from the engine to build an image's corpus. The
/// engine conforms; the store never sees a section.
protocol RuntimeInterfaceCorpusBuilding: AnyObject, Sendable {
    /// Every object of the image, nested children included, each followed by
    /// its own descendants — the order of `RuntimeObject.corpusFamily`.
    func corpusObjects(in imagePath: String) async throws -> [RuntimeObject]

    /// The prints of `family`, one outcome per object, in order. The first
    /// object is the one the others are nested in, at any depth, each listed
    /// after the object it is nested in: a nested type's own definition is
    /// taken out of its parent's print, so a family is printed as a unit —
    /// see `RuntimeInterfaceCorpusNesting`. Every interface is printed once,
    /// with `transformer`, marked for every combination of the Generation
    /// Options; an object that fails to print comes back `.failed` and the
    /// store carries on. Throws only when cancelled. The store makes the
    /// image's entries out of the prints once every family is printed — see
    /// `RuntimeInterfaceCorpusAssembly`.
    func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome]
}

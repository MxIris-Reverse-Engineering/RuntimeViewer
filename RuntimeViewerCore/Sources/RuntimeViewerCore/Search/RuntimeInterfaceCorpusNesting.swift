import Foundation
import Semantic

/// Where a corpus print's nested types lie, and how a nested type's own
/// definition is taken out of the print of the object it is nested in rather
/// than printed a second time — option D of `draft-find-navigator` §1.1.
///
/// A type's interface prints its nested types inline, and the corpus holds
/// every nested type as an entry of its own as well. The Swift printer marks
/// each nested definition it prints inline with a `DefinitionRegion` whose
/// identity is the definition's mangled name, which is the `RuntimeObject.name`
/// the sidebar lists it under (MachOSwiftSection's `marksNestedDefinitions`).
/// From those regions an entry knows the blocks its nested types take up —
/// its members are located outside them and a search skips them — and a
/// nested type gets its own definition out of its parent's print: a region,
/// moved out by the levels it sat in, is byte for byte the definition printed
/// on its own. That is MachOSwiftSection's contract, pinned by its tests.
///
/// Pure, so its rules can be tested on hand-built strings.
enum RuntimeInterfaceCorpusNesting {
    /// A print split into what a corpus entry keeps.
    struct SeparatedPrint {
        let interface: FrozenSemanticString

        let visibilityRegions: VisibilityRegionTable

        /// The blocks of the nested types listed as the object's children,
        /// ascending.
        let nestedDefinitionRanges: [Range<Int>]

        /// Every definition region of the print, the nested types' own
        /// definitions are taken out by.
        let definitionRegions: DefinitionRegionTable
    }

    /// Splits `marked`, printed with definition and visibility regions, into
    /// the entry's text, its visibility regions and the blocks the children
    /// named in `childNames` take up.
    static func separate(_ marked: FrozenSemanticString, childNames: Set<String>) -> SeparatedPrint {
        let (unmarked, definitionRegions) = marked.separatingDefinitionRegions()
        let (interface, visibilityRegions) = unmarked.separatingVisibilityRegions()
        return SeparatedPrint(
            interface: interface,
            visibilityRegions: visibilityRegions,
            nestedDefinitionRanges: nestedDefinitionRanges(in: definitionRegions, childNames: childNames),
            definitionRegions: definitionRegions
        )
    }

    /// The regions directly in the text whose identity names one of the
    /// object's children, ascending. The regions further in lie inside those,
    /// and a nested type the sidebar does not list as the object's child is
    /// not one of its entries, so its lines stay the object's.
    static func nestedDefinitionRanges(in definitionRegions: DefinitionRegionTable, childNames: Set<String>) -> [Range<Int>] {
        guard !childNames.isEmpty else { return [] }
        // The table lists its regions in text order.
        return definitionRegions.regions
            .filter { $0.depth == 0 && childNames.contains($0.identity) }
            .map { Int($0.utf8Offset) ..< Int($0.utf8Offset) + Int($0.utf8Length) }
    }

    /// Where `root`'s print holds the own definition of each object nested in
    /// it: the region with the object's name, at the depth it is nested at,
    /// inside the region of the object it is nested in — each region given to
    /// one object only. An object missing here failed to print inside its
    /// parent, or lies in a parent that did, and is printed on its own.
    static func descendantRegions(of root: RuntimeObject, in definitionRegions: DefinitionRegionTable) -> [RuntimeObjectKey: DefinitionRegionTable.Region] {
        var regionsByObject: [RuntimeObjectKey: DefinitionRegionTable.Region] = [:]
        var claimedRegionIndices: Set<Int> = []
        func visit(_ children: [RuntimeObject], depth: Int, enclosingRegionIndex: Int?) {
            for child in children {
                let regionIndex = definitionRegions.regions.indices.first { index in
                    let region = definitionRegions.regions[index]
                    return region.depth == depth
                        && region.enclosingRegionIndex == enclosingRegionIndex
                        && region.identity == child.name
                        && !claimedRegionIndices.contains(index)
                }
                guard let regionIndex else { continue }
                claimedRegionIndices.insert(regionIndex)
                regionsByObject[child.key] = definitionRegions.regions[regionIndex]
                visit(child.children, depth: depth + 1, enclosingRegionIndex: regionIndex)
            }
        }
        visit(root.children, depth: 0, enclosingRegionIndex: nil)
        return regionsByObject
    }

    /// An object's own definition as it prints on its own: its region of
    /// `marked`, moved out by the levels the region sat in. Still carries the
    /// regions of the objects nested in it, and its visibility regions.
    /// `nil` when a line of the region lacks that indentation, which a
    /// hand-written transformer not indenting by the level it is given would
    /// cause; the object is then printed on its own.
    static func ownDefinition(in marked: FrozenSemanticString, region: DefinitionRegionTable.Region) -> FrozenSemanticString? {
        marked.content(ofDefinitionRegion: region).removingIndentation(levels: region.depth + 1)
    }
}

extension RuntimeObject {
    /// The object and every object nested in it, each followed by its own
    /// descendants: the order the corpus lists an image's objects in, and
    /// the unit it prints them in.
    var corpusFamily: [RuntimeObject] {
        var family: [RuntimeObject] = []
        func append(_ object: RuntimeObject) {
            family.append(object)
            for child in object.children {
                append(child)
            }
        }
        append(self)
        return family
    }
}

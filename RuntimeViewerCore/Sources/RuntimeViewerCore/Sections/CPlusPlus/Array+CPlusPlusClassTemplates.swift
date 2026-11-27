import Foundation

extension Array where Element == RuntimeObject {
    /// These objects with each C++ class template node among them replaced by
    /// the specializations it gathers — this level only — and the C++ objects
    /// in the order they took before there were template nodes; objects of
    /// other languages keep their places ahead of them.
    ///
    /// What a namespace's or a class's interface lists as declared in it and
    /// what an export writes: the specializations, each named in full, as they
    /// always were.
    var openingCPlusPlusClassTemplateNodes: [RuntimeObject] {
        guard contains(where: { $0.kind == .cPlusPlus(.classTemplate) }) else { return self }
        let opened = flatMap { $0.kind == .cPlusPlus(.classTemplate) ? $0.children : [$0] }
        return opened.filter { !$0.kind.isCPlusPlus } + opened.filter(\.kind.isCPlusPlus).sorted()
    }
}

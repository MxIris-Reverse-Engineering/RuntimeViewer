import Foundation

extension RuntimeObject {
    /// This object with every C++ class template node replaced by the
    /// specializations it gathers (`RuntimeObjectKind.CPlusPlus.classTemplate`),
    /// all the way down: a template node gives its specializations, any other
    /// C++ object gives itself with its children replaced likewise and sorted
    /// again, and an object of another language gives itself.
    ///
    /// What a requester that does not know class template nodes is sent: the
    /// tree every build before them listed
    /// (`ObjectsInImageCommand.includesCPlusPlusClassTemplates`).
    var replacingCPlusPlusClassTemplatesWithSpecializations: [RuntimeObject] {
        if kind == .cPlusPlus(.classTemplate) {
            return children.flatMap(\.replacingCPlusPlusClassTemplatesWithSpecializations)
        }
        guard kind.isCPlusPlus, !children.isEmpty else { return [self] }
        return [withChildren(children.flatMap(\.replacingCPlusPlusClassTemplatesWithSpecializations).sorted())]
    }
}

import Foundation
import Semantic

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

import Foundation

extension Set {
    @inlinable mutating func insert<S>(contentsOf newElements: S) where S: Sequence, Element == S.Element {
        for newElement in newElements {
            insert(newElement)
        }
    }
}

import RuntimeViewerCore

extension RuntimeImageNode: @retroactive Sequence {
    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }

    public struct Iterator: IteratorProtocol {
        var stack: [RuntimeImageNode] = []

        init(node: RuntimeImageNode) {
            self.stack = [node]
        }

        public mutating func next() -> RuntimeImageNode? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }
}

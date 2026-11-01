/// Whether two arrays use one buffer — as two copies of one array value do —
/// rather than merely holding equal elements. Empty arrays never count: every
/// empty array uses the same buffer.
func sharesStorage<Element>(_ first: [Element], _ second: [Element]) -> Bool {
    guard !first.isEmpty, !second.isEmpty else { return false }
    return first.withUnsafeBufferPointer { firstBuffer in
        second.withUnsafeBufferPointer { secondBuffer in
            firstBuffer.baseAddress == secondBuffer.baseAddress
        }
    }
}

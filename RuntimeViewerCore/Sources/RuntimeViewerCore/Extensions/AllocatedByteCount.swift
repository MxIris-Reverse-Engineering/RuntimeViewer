import Foundation

extension Array {
    /// The bytes malloc hands out for an array of this many elements: its
    /// buffer's 32-byte header and the elements, rounded up to malloc's size
    /// class. Nothing for an empty array, which uses the buffer every empty
    /// array shares.
    ///
    /// Counted from `count`, not `capacity`, so an array read back from
    /// derived data and the one it was printed as count the same; a buffer an
    /// append grew past its count holds more. Only the array's own buffer:
    /// what its elements reference elsewhere is theirs to count.
    var allocatedByteCount: Int {
        guard !isEmpty else { return 0 }
        return malloc_good_size(32 + count * MemoryLayout<Element>.stride)
    }
}

extension String {
    /// The bytes malloc hands out for the string: nothing up to 15 UTF-8
    /// bytes, which Swift keeps inline, and above that a buffer with a 32-byte
    /// header and the bytes followed by a terminating zero, rounded up to
    /// malloc's size class. A string sharing its buffer with another counts it
    /// all the same.
    var allocatedByteCount: Int {
        let utf8Count = utf8.count
        guard utf8Count > 15 else { return 0 }
        return malloc_good_size(32 + utf8Count + 1)
    }
}

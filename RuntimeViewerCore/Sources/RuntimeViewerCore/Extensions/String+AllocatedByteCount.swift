import Foundation

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

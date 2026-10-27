import Foundation
import CryptoKit

extension Transformer.Configuration {
    /// Sixteen hexadecimal digits that are the same for equal configurations
    /// in every process: part of the name of a corpus stored as derived data.
    ///
    /// Not the digest of the configuration's own encoding. The C type
    /// replacements are a dictionary keyed by `Transformer.CType.Pattern`, an
    /// enum that is not `CodingKeyRepresentable`, so `JSONEncoder` writes them
    /// as one unkeyed array of keys and values in whatever order the
    /// dictionary iterates in this process — which `.sortedKeys` does not
    /// reach. Two runs with the same settings would then name their corpora
    /// differently, and each would delete the other's. The replacements are
    /// left out of the encoding and added afterwards, sorted by pattern; the
    /// rest is encoded with sorted keys.
    ///
    /// A field added to a configuration later that is again a dictionary
    /// with keys of that kind would make the digest unstable the same way.
    /// That costs a corpus read, never a wrong one: a stored corpus carries
    /// the configuration it was printed with, and a read compares the two.
    var derivedDataDigest: String {
        var configurationWithoutReplacements = self
        configurationWithoutReplacements.objc.cType.replacements = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sortedReplacements = objc.cType.replacements
            .map { [$0.key.rawValue, $0.value] }
            .sorted { $0[0] < $1[0] }
        var hash = SHA256()
        hash.update(data: (try? encoder.encode(configurationWithoutReplacements)) ?? Data())
        hash.update(data: Data([0]))
        hash.update(data: (try? encoder.encode(sortedReplacements)) ?? Data())
        return String(RuntimeDerivedDataDigest.hexadecimalString(of: hash.finalize()).prefix(16))
    }
}

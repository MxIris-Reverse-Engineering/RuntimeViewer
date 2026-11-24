import Foundation
public import Semantic
@_spi(Support) import SwiftPrinting

/// A C-imported type an interface declares that has a Swift name and a C name — `AnyWeakAttribute`
/// and `AGWeakAttribute` — with where its declared name is (proposal `c-imported-type-name-spelling`
/// in MachOSwiftSection).
///
/// The engine sends these when the request asks for them
/// (`RuntimeObjectInterface.GenerationOptions.marksCImportedTypeNames`). MachOSwiftSection marks each
/// such declared name with an annotation region whose kind carries both names; RuntimeViewer only
/// reads them back. The interface's text holds whichever name the request's
/// `SwiftGenerationOptions.cImportedTypeNameSpelling` asked for.
public struct RuntimeInterfaceCImportedTypeName: Codable, Sendable, Hashable {
    /// Where the declared name is in the interface's text, in UTF-8 offsets, as the comment structure
    /// counts them.
    public let nameUTF8Range: Range<Int>

    /// What Swift code calls the type: `AnyWeakAttribute`, or a dotted name for a type imported as a
    /// member (`NSAttributedString.Key`).
    public let swiftName: String

    /// What the type's C declaration is called, the name every mangled reference carries:
    /// `AGWeakAttribute`.
    public let cName: String

    public init(nameUTF8Range: Range<Int>, swiftName: String, cName: String) {
        self.nameUTF8Range = nameUTF8Range
        self.swiftName = swiftName
        self.cName = cName
    }

    /// The names `table` marks, in text order. Every other region of the table is left out.
    static func names(in table: AnnotationRegionTable) -> [Self] {
        table.regions.compactMap { region in
            guard let names = region.kind.cImportedTypeNames else { return nil }
            let start = Int(region.utf8Offset)
            return Self(nameUTF8Range: start ..< start + Int(region.utf8Length), swiftName: names.swiftName, cName: names.cName)
        }
        .sorted { $0.nameUTF8Range.lowerBound < $1.nameUTF8Range.lowerBound }
    }
}

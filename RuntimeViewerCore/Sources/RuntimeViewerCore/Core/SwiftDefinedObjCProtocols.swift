import MachOKit
import MachOObjCSection

/// Which of an image's Objective-C protocols were defined in Swift — what
/// `RuntimeObject.Properties.isSwiftProtocol` marks.
///
/// A protocol record says where it was written in one bit: the Swift compiler
/// writes `ProtocolDescriptorFlags::IsSwift`, bit 0, into `protocol_t.flags`
/// (`emitProtocol` in swift's `lib/IRGen/GenClass.cpp`), and clang always
/// writes zero there. The Objective-C runtime leaves bits 0–15 to Swift and
/// uses bits 29–31 itself, as does the shared cache builder for the canonical
/// copies it makes, so only bit 0 is tested, never the whole word.
///
/// The bit misses one kind of record: the copy clang emits in an image whose
/// Objective-C code reaches a Swift protocol through a `-Swift.h` header. That
/// copy keeps the protocol's runtime name, so a protocol Swift named itself —
/// the legacy mangling `_TtP<module><name>_` — is recognized by its name
/// instead. A protocol renamed with `@objc(Name)` whose only copy in the image
/// is clang's stays unrecognized: nothing in the image tells.
///
/// One image can hold two records of a protocol: Swift names its record
/// `_PROTOCOL_<name>` and clang `_OBJC_PROTOCOL_$_<name>`, so the linker keeps
/// both, while `ObjCInterfaceIndexer` keeps only the last record of a name.
/// Every record is read for that reason, and any one that qualifies marks its
/// name.
enum SwiftDefinedObjCProtocols {
    /// `ProtocolDescriptorFlags::IsSwift`.
    static let isSwiftFlag: UInt32 = 1 << 0

    /// The runtime names of the Swift-defined protocols among `records`, an
    /// image's Objective-C protocol records.
    static func names(of records: some Sequence<(name: String, flags: UInt32)>) -> Set<String> {
        var names: Set<String> = []
        for record in records where isSwiftDefined(name: record.name, flags: record.flags) {
            names.insert(record.name)
        }
        return names
    }

    /// The runtime names of the Swift-defined protocols `machO` lists.
    static func names(in machO: MachOImage) -> Set<String> {
        var records: [(name: String, flags: UInt32)] = []
        for objcProtocol in machO.objc.protocols64 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        for objcProtocol in machO.objc.protocols32 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        return names(of: records)
    }

    private static func isSwiftDefined(name: String, flags: UInt32) -> Bool {
        flags & isSwiftFlag != 0 || isLegacySwiftProtocolName(name)
    }

    /// Swift's legacy mangling of a protocol's runtime name, `_TtP<module><name>_`.
    private static func isLegacySwiftProtocolName(_ name: String) -> Bool {
        name.hasPrefix("_TtP") && name.hasSuffix("_")
    }
}

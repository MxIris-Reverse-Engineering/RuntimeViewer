/// The `Transformer` namespace and its `Module` protocol come from
/// swift-semantic-string, while the concrete modules ship with the library
/// that owns their vocabulary — `CType` / `ObjCIvarOffset` with
/// MachOObjCSection, the Swift comment kinds with MachOSwiftSection. All of
/// them extend the same namespace.
///
/// Only the aggregate `Transformer.Configuration` remains here (see
/// `Transformer+Configuration.swift`): it is the one piece that spans both
/// halves, and nothing outside RuntimeViewer needs to persist them as a unit.
///
/// These re-exports keep every existing `Transformer.…` reference in
/// RuntimeViewer compiling unchanged.
@_exported import OutputTransformer
@_exported import ObjCOutputTransformer
@_exported import SwiftOutputTransformer

import Foundation
import Semantic

/// `InterfaceCommand`'s reply. On the wire it is exactly a
/// `RuntimeObjectInterface?`, with `interfaceString` in one of the two
/// encodings peers have shipped with:
///
/// - `components`: `SemanticString`'s array of components, the only one
///   builds up to 3.0.0-beta.6 read;
/// - `columnar`: `FrozenSemanticString`'s own encoding, an order of magnitude
///   smaller, sent only to a requester that says it reads it.
///
/// Engine connections exchange no protocol version, and peers of different
/// builds are expected to talk to each other
/// (`CommunicationAndEngineArchitecture.md` §4.4), so the request states what
/// its sender reads, the reply falls back to the shape every peer reads, and
/// this type decodes either.
struct RuntimeObjectInterfaceResponse: Sendable {
    enum InterfaceStringEncoding: Sendable {
        case components
        case columnar
    }

    let interface: RuntimeObjectInterface?

    /// Chosen from the request on the serving side; recorded from what
    /// arrived on the receiving side. A relay — a proxy serving an engine
    /// that is itself a client — therefore writes the reply on in the shape
    /// it got it in, which its own requester reads: the relay forwarded that
    /// requester's request, declaration included.
    let interfaceStringEncoding: InterfaceStringEncoding
}

extension RuntimeObjectInterfaceResponse: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            interface = nil
            interfaceStringEncoding = .components
            return
        }
        do {
            interface = try container.decode(RuntimeObjectInterface.self)
            interfaceStringEncoding = .columnar
        } catch let columnarDecodingError {
            // Not the columnar shape: a peer that predates it. When it is not
            // the component shape either, the columnar failure is the one that
            // describes the current format.
            guard let componentEncodedInterface = try? container.decode(ComponentEncodedRuntimeObjectInterface.self) else {
                throw columnarDecodingError
            }
            interface = componentEncodedInterface.runtimeObjectInterface
            interfaceStringEncoding = .components
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let interface else {
            try container.encodeNil()
            return
        }
        switch interfaceStringEncoding {
        case .columnar:
            try container.encode(interface)
        case .components:
            try container.encode(ComponentEncodedRuntimeObjectInterface(interface))
        }
    }
}

/// `RuntimeObjectInterface` as builds up to 3.0.0-beta.6 declare it. Its
/// synthesized `Codable` is the point: it has to stay exactly what those
/// builds read and write, so leave its stored properties alone.
private struct ComponentEncodedRuntimeObjectInterface: Codable {
    let object: RuntimeObject
    let interfaceString: SemanticString

    init(_ interface: RuntimeObjectInterface) {
        object = interface.object
        interfaceString = SemanticString(components: interface.interfaceString.components)
    }

    /// Frozen again on the way in: past the wire, only the frozen form is handled.
    var runtimeObjectInterface: RuntimeObjectInterface {
        RuntimeObjectInterface(object: object, interfaceString: interfaceString)
    }
}

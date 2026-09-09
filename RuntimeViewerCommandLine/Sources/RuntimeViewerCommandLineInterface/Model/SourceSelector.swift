import Foundation

/// Which runtime source a command runs against.
///
/// The full set is fixed here so that later releases can serve the other
/// sources without changing any command's shape. A host that does not serve a
/// selector answers with ``CommandFailure/Code/sourceUnavailable``.
public enum SourceSelector: Hashable, Sendable {
    /// The runtime of the host process itself. The default.
    case local
    /// The Mac Catalyst runtime, served through the Catalyst helper.
    case macCatalyst
    /// A process the host injected into, addressed by process identifier.
    case attachedProcess(processIdentifier: Int32)
    /// A process the host injected into, addressed by name.
    case attachedProcessNamed(String)
    /// Any engine the host knows, addressed by its engine identifier.
    case engine(identifier: String)
}

// MARK: - Textual form

extension SourceSelector: LosslessStringConvertible {
    /// Parses the form used on the command line and on the wire:
    /// `local`, `catalyst`, `pid:<number>`, `process:<name>`, `engine:<identifier>`.
    public init?(_ description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "local":
            self = .local
            return
        case "catalyst", "maccatalyst":
            self = .macCatalyst
            return
        default:
            break
        }
        guard let separatorIndex = trimmed.firstIndex(of: ":") else { return nil }
        let prefix = trimmed[..<separatorIndex].lowercased()
        let value = String(trimmed[trimmed.index(after: separatorIndex)...])
        guard !value.isEmpty else { return nil }
        switch prefix {
        case "pid":
            guard let processIdentifier = Int32(value) else { return nil }
            self = .attachedProcess(processIdentifier: processIdentifier)
        case "process":
            self = .attachedProcessNamed(value)
        case "engine":
            self = .engine(identifier: value)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .local:
            return "local"
        case .macCatalyst:
            return "catalyst"
        case .attachedProcess(let processIdentifier):
            return "pid:\(processIdentifier)"
        case .attachedProcessNamed(let name):
            return "process:\(name)"
        case .engine(let identifier):
            return "engine:\(identifier)"
        }
    }
}

// MARK: - Codable (single string)

extension SourceSelector: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let selector = SourceSelector(rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized source selector '\(rawValue)'")
        }
        self = selector
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

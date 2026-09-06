import Foundation

/// `--json` output: exactly one JSON document on standard output, for both
/// results and failures.
public enum JSONRenderer {
    public static func render(_ result: CommandResult) throws -> String {
        try render(AnyEncodable(result.payload))
    }

    public static func render(_ failure: CommandFailure) -> String {
        (try? render(FailureDocument(error: failure))) ?? "{\"error\":{\"code\":\"internalError\",\"message\":\"Could not encode the failure.\"}}\n"
    }

    public static func render<Document: Encodable>(_ document: Document) throws -> String {
        let encoder = WireCoding.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private struct FailureDocument: Encodable {
        let error: CommandFailure
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable

        init(_ value: any Encodable) {
            self.value = value
        }

        func encode(to encoder: any Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

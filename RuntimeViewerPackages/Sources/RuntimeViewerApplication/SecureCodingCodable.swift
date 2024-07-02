import Foundation

@propertyWrapper
public struct SecureCodingCodable<T>: Codable, Hashable where T: NSObject & NSSecureCoding {
    public enum WrapperError: Error {
        case decoderError
    }
    public var wrappedValue: T

    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let data = try NSKeyedArchiver.archivedData(withRootObject: wrappedValue, requiringSecureCoding: true)
        try container.encode(data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: T.self, from: data) else {
            throw WrapperError.decoderError
        }
        self.wrappedValue = value
    }
}

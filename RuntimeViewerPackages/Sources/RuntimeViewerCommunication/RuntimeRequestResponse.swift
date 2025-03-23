import Foundation
import OSLog

public let RuntimeViewerMachServiceName = "com.JH.RuntimeViewerService"

public protocol RuntimeRequest: Codable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

public protocol RuntimeResponse: Codable {}

public struct VoidResponse: RuntimeResponse, Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}


//public struct AnyRuntimeRequest<Value: Codable>: RuntimeRequest {
//
//    public typealias Response = AnyRuntimeResponse<Value>
//
//    public static let identifier: String
//    
//    public var wrappedValue: Value
//
//    public init(identifier: String, wrappedValue: Value) {
//        self.identifier = identifier
//        self.wrappedValue = wrappedValue
//    }
//}
//
//
//public struct AnyRuntimeResponse<Value: Codable>: RuntimeResponse {
//    public var wrappedValue: Value
//}

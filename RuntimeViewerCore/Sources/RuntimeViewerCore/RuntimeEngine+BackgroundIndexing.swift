import Foundation
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {
            let hasObjC = await objcSectionFactory.hasCachedSection(for: path)
            let hasSwift = await swiftSectionFactory.hasCachedSection(for: path)
            return hasObjC && hasSwift
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .isImageIndexed, request: path)
        }
    }
}

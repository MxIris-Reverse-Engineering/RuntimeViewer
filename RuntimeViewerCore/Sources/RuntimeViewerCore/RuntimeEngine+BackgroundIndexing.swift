import Foundation
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {
            let normalized = DyldUtilities.patchImagePathForDyld(path)
            let hasObjC = await objcSectionFactory.hasCachedSection(for: normalized)
            let hasSwift = await swiftSectionFactory.hasCachedSection(for: normalized)
            return hasObjC && hasSwift
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .isImageIndexed, request: path)
        }
    }
}

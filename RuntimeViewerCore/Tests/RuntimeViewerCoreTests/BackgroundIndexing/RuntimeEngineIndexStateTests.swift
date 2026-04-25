import XCTest
@testable import RuntimeViewerCore

final class RuntimeEngineIndexStateTests: XCTestCase {
    func test_isImageIndexed_falseForUnvisitedPath() async throws {
        let engine = RuntimeEngine(source: .local)
        let indexed = try await engine.isImageIndexed(path: "/never/seen")
        XCTAssertFalse(indexed)
    }

    func test_isImageIndexed_trueAfterLoadImage() async throws {
        let engine = RuntimeEngine(source: .local)
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        try await engine.loadImage(at: foundation)
        let indexed = try await engine.isImageIndexed(path: foundation)
        XCTAssertTrue(indexed)
    }
}

#if os(macOS)

import Testing
import Foundation
import HelperCommunication
import RuntimeViewerCommunication

// MARK: - RuntimeRequest <-> HelperCommunication.Request protocol merge

@Suite("RuntimeRequest protocol merge")
struct RuntimeRequestProtocolMergeTests {
    /// Compile-time assertion: every `RuntimeRequest` automatically satisfies
    /// `HelperCommunication.Request`, so business requests can be mounted onto a lib
    /// `HelperService` / `HelperPeerClient` / `HelperPeerServer` without adapters.
    @Test("Business RuntimeRequest satisfies HelperCommunication.Request")
    func businessRequestsConformToLibRequest() {
        let _: any HelperCommunication.Request = OpenApplicationRequest(
            url: URL(fileURLWithPath: "/"),
            callerPID: 0
        )
        let _: any HelperCommunication.Request = FileOperationRequest(
            operation: .remove(url: URL(fileURLWithPath: "/tmp/x"))
        )
        let _: any HelperCommunication.Request = InjectApplicationRequest(
            pid: 0,
            dylibURL: URL(fileURLWithPath: "/")
        )
        let _: any HelperCommunication.Request = FetchAllInjectedEndpointsRequest()
        let _: any HelperCommunication.Request = RemoveInjectedEndpointRequest(pid: 0)
    }

    /// `VoidResponse` is now `Codable & Sendable`, satisfying both `RuntimeResponse` and
    /// the `Codable & Sendable` constraint inherited from `HelperCommunication.Request`.
    /// The lib also exposes its own `HelperCommunication.VoidResponse`; tests use the
    /// fully-qualified name to disambiguate.
    @Test("VoidResponse satisfies both protocols' Response requirement")
    func voidResponseConforms() {
        let _: any RuntimeResponse = RuntimeViewerCommunication.VoidResponse.empty
        let _: any (Codable & Sendable) = RuntimeViewerCommunication.VoidResponse.empty
    }

    /// Business identifier namespace must remain stable so a Phase 2 daemon swap or a
    /// rolling upgrade does not silently break the wire protocol.
    @Test("Business RuntimeRequest identifiers stay on com.JH.RuntimeViewerService.*")
    func businessIdentifiersUseRuntimeViewerServiceNamespace() {
        #expect(OpenApplicationRequest.identifier == "com.JH.RuntimeViewerService.OpenApplicationRequest")
        #expect(InjectApplicationRequest.identifier == "com.JH.RuntimeViewerService.InjectApplication")
        #expect(FileOperationRequest.identifier == "com.JH.RuntimeViewerService.FileOperationRequest")
        #expect(RegisterInjectedEndpointRequest.identifier == "com.JH.RuntimeViewerService.RegisterInjectedEndpoint")
        #expect(FetchAllInjectedEndpointsRequest.identifier == "com.JH.RuntimeViewerService.FetchAllInjectedEndpoints")
        #expect(RemoveInjectedEndpointRequest.identifier == "com.JH.RuntimeViewerService.RemoveInjectedEndpoint")
    }
}

#endif

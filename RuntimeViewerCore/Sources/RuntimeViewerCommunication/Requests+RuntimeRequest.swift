#if canImport(AppKit) && !targetEnvironment(macCatalyst)

public import HelperCommunication
public import ApplicationsServiceInterface
public import FilesServiceInterface
public import InjectionServiceInterface
public import InjectedEndpointRegistryServiceInterface

// MARK: - Response conformances

extension HelperCommunication.VoidResponse: RuntimeResponse {}

extension FetchAllInjectedEndpointsRequest.Response: RuntimeResponse {}

// MARK: - Request conformances
//
// Business request types live in swift-helper-service so the helper binary can
// implement them; here we conform them to RuntimeViewer's own `RuntimeRequest`
// protocol so the existing `RuntimeConnection` / `RuntimeMessageChannel` generic
// surface keeps working without changes.

extension OpenApplicationRequest: RuntimeRequest {}

extension FileOperationRequest: RuntimeRequest {}

extension InjectApplicationRequest: RuntimeRequest {}

extension RegisterInjectedEndpointRequest: RuntimeRequest {}

extension FetchAllInjectedEndpointsRequest: RuntimeRequest {}

extension RemoveInjectedEndpointRequest: RuntimeRequest {}

#endif

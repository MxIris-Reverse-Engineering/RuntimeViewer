import Testing
import Dependencies
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// The dependencies RuntimeViewerAppCore declares and RuntimeViewerAppUI implements (proposal
/// `app-core-ui-split`): AppCore gives each key its test value, AppUI its live value.
@Suite("Dependencies declared in AppCore, implemented in AppUI")
struct CrossLayerDependencyTests {
    /// Without these conformances a live run would find no value for the key and stop.
    @Test("Once RuntimeViewerAppUI is linked, each of the keys has its live value")
    func appUIProvidesTheLiveValues() {
        let keyTypes: [Any.Type] = [
            AppRouterKey.self,
            RuntimeEngineIconProvidingKey.self,
            RuntimeObjectIconRenderingKey.self,
        ]
        for keyType in keyTypes {
            #expect(keyType is any DependencyKey.Type, "\(keyType) has no live value")
        }
    }

    @Test("The router a test gets by default records an issue instead of opening a window")
    @MainActor
    func unimplementedRouterRecordsAnIssue() {
        withKnownIssue {
            UnimplementedRouter<AppRoute>().trigger(.settings)
        }
    }
}

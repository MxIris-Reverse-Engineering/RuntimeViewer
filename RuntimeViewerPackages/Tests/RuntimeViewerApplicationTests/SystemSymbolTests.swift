import AppKit
import Testing
@testable import RuntimeViewerAppCore

/// The system symbols RuntimeViewerAppCore draws. They are named by string since the module stopped
/// depending on SFSymbols (proposal `draft-app-core-ui-split`), so a misspelt name is caught here
/// rather than by SFSymbols' typed cases at compile time.
@Suite("System symbols")
struct SystemSymbolTests {
    @Test("The system has every symbol the module draws", arguments: SystemSymbol.allCases)
    func systemHasSymbol(symbol: SystemSymbol) {
        #expect(
            NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil) != nil,
            "the system has no symbol named \(symbol.rawValue)"
        )
    }

    @Test("Asking for a symbol the system does not have stops the process, as SFSymbols did")
    func missingSymbolStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            _ = SystemSymbol.image(named: "runtimeviewer.no.such.symbol")
        }
    }
}

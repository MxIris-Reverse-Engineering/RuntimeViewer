// Only the iOS app's target links the SourceEditor bridge, and only it defines
// RUNTIME_VIEWER_SOURCE_EDITOR (for the iOS and simulator SDKs). The jailbroken variant and the
// visionOS app compile the same folder without it, and show interfaces in the text view.
#if RUNTIME_VIEWER_SOURCE_EDITOR

import UIKit
import Dependencies
import DependenciesMacros
import RuntimeViewerSourceEditorBridge

/// Hands the content pages their SourceEditor bridges and the framework's own themes: the iOS
/// counterpart of the macOS app's provider of the same name. It does not prewarm a bridge as that
/// one does — what the prewarm saves there is the minimap's first Metal compile, and the minimap is
/// off by default.
@MainActor
final class SourceEditorBridgeProvider {
    fileprivate static let shared = SourceEditorBridgeProvider()

    /// Read from disk once each; every content page asks for one on every appearance change.
    private var builtInThemeDictionariesByName: [String: NSDictionary] = [:]

    private init() {}

    /// A new bridge with its own editor view, or nil when this build carries no SourceEditor —
    /// a checkout that could not download the frameworks, or the simulator's x86_64 slice.
    func makeBridge() -> SourceEditorBridging? {
        SourceEditorBridgeFactory.makeBridge()
    }

    /// One of the `.xccolortheme` files the framework ships, such as `Default (Dark)`.
    func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        if let themeDictionary = builtInThemeDictionariesByName[themeName] {
            return themeDictionary
        }
        let themeDictionary = SourceEditorBridgeFactory.builtInThemeDictionary(named: themeName)
        builtInThemeDictionariesByName[themeName] = themeDictionary
        return themeDictionary
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SourceEditorBridgeProvider.shared })
    var sourceEditorBridgeProvider: SourceEditorBridgeProvider
}

#endif

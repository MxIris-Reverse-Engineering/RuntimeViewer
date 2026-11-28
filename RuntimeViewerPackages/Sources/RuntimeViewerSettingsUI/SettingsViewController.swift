#if os(iOS) || os(visionOS)

import UIKit
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// RuntimeViewer's settings on iOS and visionOS: the pages whose settings act
/// on something there, presented as UIFoundation's settings list. Editor is
/// among them only where the app carries the reconstructed SourceEditor
/// frameworks — the iOS app; not the jailbroken variant (arm64e, which the
/// frameworks have no slice for) nor visionOS.
///
/// The macOS window (`SettingsWindowController`) has more pages; the others
/// join this list when what they configure comes to these platforms. A fresh
/// instance is presented each time — unlike the macOS window there is nothing
/// to keep between presentations. Public because the iOS app, outside this
/// package, presents it.
public final class SettingsViewController: UIFoundationSettingsUI.SettingsViewController {
    public init() {
        super.init(title: "Settings") {
            SettingsPage("Appearance", id: "appearance", plainSymbol: "circle.lefthalf.filled") {
                AppearanceSettingsView()
            }
            SettingsPage("Theme", id: "theme", plainSymbol: "paintpalette") {
                ThemeSettingsView()
            }
            SettingsPage("Generation Options", id: RuntimeViewerSettings.Settings.PageIdentifier.generationOptions.rawValue, plainSymbol: "ellipsis.curlybraces") {
                GenerationOptionsSettingsView()
            }
            SettingsPage("Transformer", id: "transformer", plainSymbol: "arrow.triangle.2.circlepath") {
                TransformerSettingsView()
            }
            if case .available = SourceEditorFrameworks.availability {
                SettingsPage("Editor", id: "editor", plainSymbol: "text.alignleft") {
                    EditorSettingsView()
                }
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif

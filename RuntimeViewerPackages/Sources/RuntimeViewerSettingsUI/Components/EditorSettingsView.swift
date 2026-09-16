#if os(macOS)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct EditorSettingsView: View {
    @Dependency(\.applicationRelauncher) private var applicationRelauncher

    @AppSettings(\.editor)
    var settings

    /// Every Xcode the picker offers, plus a row for a stored choice that is no longer among
    /// them — otherwise picking a copy and then deleting it would leave the picker showing
    /// "Automatic" while the stored path still said otherwise.
    ///
    /// Resolved on appearance and whenever the choice changes, rather than on every redraw:
    /// building one row stats four framework binaries, and installing an Xcode while this window
    /// is open is not worth watching for.
    @State private var selectableXcodes: [XcodeSourceEditorLocator.XcodeInstallation] = []

    /// Where the current choice would load the frameworks from, which is not the same question as
    /// where this process already loaded them from — see ``loadedFrameworksDirectory``.
    ///
    /// Seeded with the automatic answer so the first frame does not draw the whole pane disabled;
    /// `refreshXcodes()` replaces it with the one that accounts for the stored choice. Seeding it
    /// is cheap — a handful of `stat`s — where seeding ``selectableXcodes`` would ask
    /// LaunchServices on every redraw, which is why that one waits for `onAppear`.
    @State private var frameworksDirectory: URL? = XcodeSourceEditorLocator.frameworksDirectory()

    /// What the running process actually has loaded, or `nil` while the editor has never been
    /// brought up. The frameworks are `dlopen`ed once and never unloaded, so this is what decides
    /// whether a relaunch is the only way to act on a change.
    @State private var loadedFrameworksDirectory: URL?

    private var isSourceEditorInstalled: Bool { frameworksDirectory != nil }

    private var preferredXcodeBundleURL: URL? {
        settings.sourceEditorXcodePath.isEmpty ? nil : URL(fileURLWithPath: settings.sourceEditorXcodePath)
    }

    private var selectedXcode: XcodeSourceEditorLocator.XcodeInstallation? {
        selectableXcodes.first { $0.id == settings.sourceEditorXcodePath }
    }

    /// How to name what is loaded, for the relaunch notice. Reduces
    /// `…/Xcode-26.6.app/Contents/SharedFrameworks` to `Xcode-26.6.app`, and falls back to the
    /// whole path for a directory that is not inside an app bundle — which is what an embedded
    /// copy would look like.
    private var loadedFrameworksDescription: String? {
        guard let loadedFrameworksDirectory else { return nil }
        let bundleURL = loadedFrameworksDirectory.deletingLastPathComponent().deletingLastPathComponent()
        guard bundleURL.pathExtension == "app" else { return loadedFrameworksDirectory.path }
        return bundleURL.lastPathComponent
    }

    /// True once the editor is running on something other than what the current choice resolves
    /// to. Comparing the resolved directories rather than the stored path is what keeps this
    /// quiet when "Automatic" and an explicit choice name the same copy.
    private var needsRelaunchToTakeEffect: Bool {
        guard let loadedFrameworksDirectory, let frameworksDirectory else { return false }
        return loadedFrameworksDirectory.standardizedFileURL != frameworksDirectory.standardizedFileURL
    }

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Use Xcode's Source Editor", isOn: $settings.usesSourceEditor)
                    .disabled(!isSourceEditorInstalled)

                // Deliberately *not* gated on the toggle above. The toggle disables itself when no
                // Xcode can be found, so gating these on it would leave a user whose Xcode sits
                // somewhere LaunchServices does not know about unable to point at it — which is
                // the one case they exist for.

                Picker("Xcode", selection: $settings.sourceEditorXcodePath) {
                    Text("Automatic").tag("")
                    ForEach(selectableXcodes) { installation in
                        Text(installation.displayName).tag(installation.id)
                    }
                }

                HStack {
                    Spacer()
                    Button("Choose Another Xcode…") {
                        chooseAnotherXcode()
                    }
                }
            } header: {
                Text("Engine")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Renders interfaces with the editor from Xcode instead of the built-in text view, adding code folding, sticky headers, a minimap, scope guides and ⌘-hover underlining. Large interfaces scroll without dropping frames.")

                    if isSourceEditorInstalled {
                        Text("Takes effect the next time content is displayed — select something in the sidebar to see the change.")
                    } else {
                        Label(
                            "Requires Xcode. No installed copy was found, so RuntimeViewer will keep using its built-in text view.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }

                    if let selectedXcode, !selectedXcode.providesRequiredFrameworks {
                        Label(
                            "\(selectedXcode.displayName) does not contain the editor frameworks. RuntimeViewer will fall back to the next Xcode it finds.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }

                    if needsRelaunchToTakeEffect, let loadedFrameworksDescription {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label(
                                "This session is running the editor from \(loadedFrameworksDescription). The frameworks are loaded once and cannot be swapped in a running process — relaunch to use the Xcode selected above.",
                                systemImage: "arrow.clockwise"
                            )
                            .foregroundStyle(.secondary)

                            Button("Relaunch RuntimeViewer") {
                                applicationRelauncher.relaunch()
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Line Numbers", isOn: $settings.showsLineNumbers)
                Toggle("Code Folding Ribbon", isOn: $settings.showsFoldingRibbon)
                Toggle("Sticky Headers", isOn: $settings.showsStickyHeaders)
                Toggle("Minimap", isOn: $settings.showsMinimap)
                Toggle("Scope Guides", isOn: $settings.showsScopeGuides)
                Toggle("Invisibles", isOn: $settings.showsInvisibles)
                Toggle("Mark Separators", isOn: $settings.showsMarkSeparators)
            } header: {
                Text("Display")
            } footer: {
                Text("Changes apply immediately. Sticky headers pin the enclosing declarations to the top of the view while scrolling; the folding ribbon draws the arrows that collapse a declaration. Mark separators draw a rule at every MARK comment, and have nothing to draw until generated interfaces contain them.")
            }
            .disabled(!isSourceEditorInstalled || !settings.usesSourceEditor)

            Section {
                Label(
                    "Syntax coloring uses the runtime metadata the interface was generated from, not Xcode's own tokenizer — the same information the built-in text view colors from. The exception is a token the editor parses as spanning two of those runs, such as a parameter type and the parameter name after it, which keeps the editor's own reading.",
                    systemImage: "paintpalette"
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Syntax Coloring")
            }
        }
        .onAppear(perform: refreshXcodes)
        .onChange(of: settings.sourceEditorXcodePath) { _, _ in
            refreshXcodes()
        }
    }

    private func refreshXcodes() {
        var installations = XcodeSourceEditorLocator.installedXcodes()
        let chosenPath = settings.sourceEditorXcodePath
        if !chosenPath.isEmpty, !installations.contains(where: { $0.id == chosenPath }) {
            installations.append(.init(bundleURL: URL(fileURLWithPath: chosenPath)))
        }
        selectableXcodes = installations
        frameworksDirectory = XcodeSourceEditorLocator.frameworksDirectory(preferring: preferredXcodeBundleURL)
        loadedFrameworksDirectory = XcodeSourceEditorLocator.loadedFrameworksDirectory()
    }

    /// For a copy LaunchServices does not know about — one that was never launched, or one a
    /// version manager keeps outside `/Applications`.
    ///
    /// Whatever is chosen is stored as-is. A bundle that turns out not to hold the frameworks is
    /// reported by the footer above rather than rejected here, so the pane says what is wrong
    /// with the choice instead of silently declining it.
    private func chooseAnotherXcode() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Xcode to load the source editor from."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        settings.sourceEditorXcodePath = chosenURL.standardizedFileURL.path
    }
}

#endif

import SwiftUI
import RuntimeViewerCore
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// Settings › Generation Options (proposal `generation-options-image-overrides`): the global options
/// every image prints with, and on the Mac the images that override some of them.
///
/// An override is made and changed from the image's own sheet in a document window (Editor ›
/// Generation Options for “<image>”…), the one place that knows which image is meant; this page
/// lists what the overrides hold and puts an option, or a whole image, back on the global options.
struct GenerationOptionsSettingsView: View {
    @AppSettings(\.generationOptions)
    var settings

    var body: some View {
        SettingsForm {
            ForEach(Settings.GenerationOption.Section.allCases, id: \.self) { section in
                Section {
                    ForEach(section.options, id: \.self) { option in
                        GenerationOptionRow(option: option, options: $settings.global)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if section == Settings.GenerationOption.Section.allCases.last {
                        Text("These options apply to every image. An image can override some of them; its other options keep following these.")
                    }
                }
            }

            #if os(macOS)
            ImageOverridesSection(settings: $settings)
            #endif
        }
    }
}

/// One option as a control: a toggle, or a segmented choice among an enumeration's cases.
private struct GenerationOptionRow: View {
    let option: Settings.GenerationOption

    @Binding
    var options: RuntimeObjectInterface.GenerationOptions

    var body: some View {
        switch option.control {
        case .toggle(let keyPath):
            Toggle(option.title, isOn: $options[dynamicMember: keyPath])
        case .choice(let choice):
            Picker(option.title, selection: Binding(
                get: { choice.selectedIndex(options) },
                set: { selectedIndex in choice.select(selectedIndex, &options) }
            )) {
                ForEach(choice.labels.indices, id: \.self) { index in
                    Text(choice.labels[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

#if os(macOS)

/// The images that override some of the global options, each with what it overrides.
private struct ImageOverridesSection: View {
    @Binding
    var settings: Settings.GenerationOptionsSettings

    /// By engine, then by image, so one engine's images stay together.
    private var sortedOverrides: [Settings.ImageGenerationOptionsOverride] {
        settings.imageOverrides.sorted { first, second in
            if first.engine.name != second.engine.name {
                return first.engine.name.localizedStandardCompare(second.engine.name) == .orderedAscending
            }
            return first.imageName.localizedStandardCompare(second.imageName) == .orderedAscending
        }
    }

    var body: some View {
        Section {
            if settings.imageOverrides.isEmpty {
                Text("No image overrides any option.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedOverrides) { override in
                    DisclosureGroup {
                        ForEach(Settings.GenerationOption.allCases.filter(override.overriddenOptions.contains), id: \.self) { option in
                            HStack {
                                Text(option.title)
                                Spacer()
                                Text(option.displayValue(in: override.values))
                                    .foregroundStyle(.secondary)
                                Button {
                                    settings.revert(option, forImageAt: override.imagePath, engineKey: override.engine.key)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .help("Use the global value")
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(override.imageName)
                                Text(override.engine.name.isEmpty ? override.engine.key : override.engine.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .help(override.imagePath)
                            Spacer()
                            Text(override.overriddenOptions.count == 1 ? "1 option" : "\(override.overriddenOptions.count) options")
                                .foregroundStyle(.secondary)
                            Button("Remove") {
                                settings.removeOverride(forImageAt: override.imagePath, engineKey: override.engine.key)
                            }
                            .help("Put every option of this image back on the global options")
                        }
                    }
                }
            }
        } header: {
            Text("Image Overrides")
        } footer: {
            Text("Set an image's own options from Editor › Generation Options for This Image… in a window showing it. Options it does not override follow the global ones.")
        }
    }
}

#endif

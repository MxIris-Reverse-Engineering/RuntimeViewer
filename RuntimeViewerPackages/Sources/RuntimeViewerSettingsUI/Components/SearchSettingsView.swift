#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct SearchSettingsView: View {
    @AppSettings(\.search)
    var search

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Keep Interfaces Searchable", isOn: $search.isCorpusEnabled)

                Stepper(
                    "Resident Limit (MB)",
                    value: $search.residentByteLimitMegabytes.asDouble,
                    in: 32...4096,
                    step: 32,
                    format: .number.precision(.fractionLength(0))
                )
                .disabled(!search.isCorpusEnabled)
            } header: {
                Text("Find Navigator")
            } footer: {
                Text("Text and member searches read a corpus: the interface of every object in an indexed image, printed once with every annotation on and your transformer settings. It is built when an image is indexed or opened, in the process that owns the image, and dropped when the image is unloaded. Past the resident limit, the images searched least recently are dropped and rebuilt on demand. Ancestor, Descendant and Conforming Types need no corpus.")
            }
        }
    }
}

#endif

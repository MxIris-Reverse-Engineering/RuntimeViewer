#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct SearchSettingsView: View {
    @AppSettings(\.search)
    var search

    private static let maximumConcurrentScansUpperBound = max(1, ProcessInfo.processInfo.processorCount)

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
                Text("Text and member searches read a corpus: the interface of every object in an indexed image, printed once with every annotation on and your transformer settings. It is built when an image is indexed or opened, in the process that owns the image, kept on disk for the next launch, and dropped when the image is unloaded. The images searched most recently stay in memory up to the resident limit; the others are read back from disk when a search needs them. Ancestor, Descendant and Conforming Types need no corpus.")
            }

            Section {
                Toggle("Keep Cross References Ready", isOn: $search.isCrossReferencePreparationEnabled)

                Stepper(
                    "Resident Limit (MB)",
                    value: $search.crossReferenceResidentByteLimitMegabytes.asDouble,
                    in: 32...4096,
                    step: 32,
                    format: .number.precision(.fractionLength(0))
                )
                .disabled(!search.isCrossReferencePreparationEnabled)

                Stepper(
                    "Max Concurrent Scans",
                    value: $search.maximumConcurrentCrossReferenceScans.asDouble,
                    in: 1...Double(Self.maximumConcurrentScansUpperBound),
                    format: .number.precision(.fractionLength(0))
                )
            } header: {
                Text("Cross References")
            } footer: {
                Text("Call Hierarchy and Type References, in the Find navigator and the Inspector, read the machine code of indexed images only. Kept ready, indexed images are read in the background, Always Index images first, until the resident limit is full — the Report navigator shows how far — and queries answer from what was read. A query reads any other image it needs, and the images queried least recently are dropped to stay within the limit. Max Concurrent Scans limits how many images are read at the same time, each keeping a core busy: higher values finish sooner, lower ones leave more of the Mac to everything else.")
            }
        }
    }
}

#endif

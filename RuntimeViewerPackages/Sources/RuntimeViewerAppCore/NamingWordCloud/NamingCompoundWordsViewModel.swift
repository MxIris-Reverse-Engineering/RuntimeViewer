#if os(macOS)

import Foundation
import RuntimeViewerArchitectures

/// The Compound Words sheet of the naming word cloud: the words counted as
/// one, the presets first. Removing a preset and adding a word are stored as
/// changes to the presets (`NamingWordCloudPreferences`), which every word
/// cloud window follows.
public final class NamingCompoundWordsViewModel: ViewModel<NamingWordCloudRoute> {
    public struct Row: Hashable, Sendable {
        public let word: String
        public let isPreset: Bool

        public var detail: String {
            isPreset ? "Preset" : "Added"
        }
    }

    public struct Input {
        /// A word typed in the sheet's field.
        public let addWord: Signal<String>
        /// Rows to remove, by index.
        public let removeRows: Signal<[Int]>
        public let restorePresets: Signal<Void>
        public let done: Signal<Void>

        public init(addWord: Signal<String>, removeRows: Signal<[Int]>, restorePresets: Signal<Void>, done: Signal<Void>) {
            self.addWord = addWord
            self.removeRows = removeRows
            self.restorePresets = restorePresets
            self.done = done
        }
    }

    public struct Output {
        public let rows: Driver<[Row]>
        /// Why a typed word was not added, once per refusal.
        public let refusal: Signal<String>
    }

    @RxObserved
    public private(set) var rows: [Row] = []

    private let refusalRelay = PublishRelay<String>()

    public override init(documentState: DocumentState, router: any Router<NamingWordCloudRoute>) {
        super.init(documentState: documentState, router: router)
        rows = Self.rows(for: appDefaults.namingWordCloudPreferences)
    }

    public func transform(_ input: Input) -> Output {
        appDefaults.$namingWordCloudPreferences
            .observeOnMainScheduler()
            .subscribeOnNextMainActor { [weak self] preferences in
                guard let self else { return }
                let updatedRows = Self.rows(for: preferences)
                if updatedRows != rows {
                    rows = updatedRows
                }
            }
            .disposed(by: rx.disposeBag)

        input.addWord.emitOnNextMainActor { [weak self] word in
            guard let self else { return }
            add(word.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .disposed(by: rx.disposeBag)

        input.removeRows.emitOnNextMainActor { [weak self] indices in
            guard let self else { return }
            remove(indices.compactMap { self.rows.indices.contains($0) ? self.rows[$0] : nil })
        }
        .disposed(by: rx.disposeBag)

        input.restorePresets.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            update { $0.removedPresetCompoundWords = [] }
        }
        .disposed(by: rx.disposeBag)

        input.done.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            router.trigger(.closeCompoundWords)
        }
        .disposed(by: rx.disposeBag)

        return Output(rows: $rows.asDriver(), refusal: refusalRelay.asSignal())
    }

    private func add(_ word: String) {
        guard !word.isEmpty else { return }
        let key = word.lowercased()
        // A preset is brought back however it is typed — `datasource` too,
        // which on its own reads as one word.
        if NamingCompoundWords.presetWords.contains(where: { $0.lowercased() == key }) {
            update { $0.removedPresetCompoundWords.removeAll { $0.lowercased() == key } }
            return
        }
        guard NamingWordTokenizer.words(in: word).count >= 2 else {
            refusalRelay.accept("“\(word)” is a single word. A compound word is two or more, capitalized where each begins, such as DataSource.")
            return
        }
        update { preferences in
            if !preferences.addedCompoundWords.contains(where: { $0.lowercased() == key }) {
                preferences.addedCompoundWords.append(word)
            }
        }
    }

    private func remove(_ removedRows: [Row]) {
        guard !removedRows.isEmpty else { return }
        update { preferences in
            for row in removedRows {
                let key = row.word.lowercased()
                if row.isPreset {
                    if !preferences.removedPresetCompoundWords.contains(where: { $0.lowercased() == key }) {
                        preferences.removedPresetCompoundWords.append(row.word)
                    }
                } else {
                    preferences.addedCompoundWords.removeAll { $0.lowercased() == key }
                }
            }
        }
    }

    private func update(_ change: (inout NamingWordCloudPreferences) -> Void) {
        var preferences = appDefaults.namingWordCloudPreferences
        change(&preferences)
        appDefaults.namingWordCloudPreferences = preferences
        rows = Self.rows(for: preferences)
    }

    /// The presets still in effect, then the added words, each once.
    static func rows(for preferences: NamingWordCloudPreferences) -> [Row] {
        let presetKeys = Set(NamingCompoundWords.presetWords.map { $0.lowercased() })
        return preferences.compoundWords.words.map { Row(word: $0, isPreset: presetKeys.contains($0.lowercased())) }
    }
}

#endif

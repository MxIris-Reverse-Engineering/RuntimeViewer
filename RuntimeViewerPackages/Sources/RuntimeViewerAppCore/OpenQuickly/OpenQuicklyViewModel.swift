#if os(macOS)

import Foundation
import MemberwiseInit
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// File › Open Quickly… (⇧⌘O): the floating bar over a document window. It searches what an empty
/// editor pane's start page searches — the engine's images by name and the objects of the images it
/// has indexed — because Xcode's Open Quickly window and its initial editor share one search
/// (proposal `editor-start-page`). Unlike the start page's field, which Xcode holds back until
/// three characters, the bar searches from the first one, as Xcode's window does.
///
/// The bar asks for the matches of each term it shows and takes only the answer to that term, so
/// the matches come out with the term they answer; a newer term cancels the search of the one
/// before. What is chosen opens in the focused pane, where the modifier keys say.
public final class OpenQuicklyViewModel: ViewModel<MainRoute> {
    /// What one term matched, best first.
    public struct Matches: Equatable {
        public let searchText: String
        public let items: [ContentStartPageItemCellViewModel]
    }

    /// How many matches the bar lists.
    public nonisolated static let maximumResultCount = 100

    @MemberwiseInit(.public)
    public struct Input {
        /// The bar's text, every term it asks about.
        @Init(default: Signal<String>.empty())
        public let searchText: Signal<String>
        /// A match chosen, and where it goes.
        @Init(default: Signal<ContentStartPageItemOpening>.empty())
        public let itemOpened: Signal<ContentStartPageItemOpening>
        /// The bar closed: the search ends.
        @Init(default: Signal<Void>.empty())
        public let dismissed: Signal<Void>
    }

    public struct Output {
        public let matches: Signal<Matches>
    }

    private lazy var openQuicklySearch = OpenQuicklySearch(documentState: documentState)

    private let matchesRelay = PublishRelay<Matches>()

    /// Ends the search under way — the bar closed, a match opened, the window moved to another
    /// engine — dropping a term still being answered along with the catalog.
    private let searchResetRelay = PublishRelay<Void>()

    /// One term's answer, with the engine it was read from: an answer read from an engine the window
    /// has since left is no answer.
    private struct Answer {
        let searchText: String
        let entries: [OpenQuicklyCatalog.Entry]
        let engine: RuntimeEngine
    }

    public override init(documentState: DocumentState, router: any Router<MainRoute>) {
        super.init(documentState: documentState, router: router)

        // A window moved to another engine searches that engine's images: the search under way
        // ends, and the next term reads the new engine.
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .distinctUntilChanged { $0 === $1 }
            .skip(1)
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                searchResetRelay.accept(())
            }
            .disposed(by: rx.disposeBag)
    }

    public func transform(_ input: Input) -> Output {
        // A reset comes through the same stream as the terms, so that it drops the term still being
        // answered: ending only the catalog would leave that search to read a new one.
        Observable.merge(
            input.searchText.asObservable().map { Optional($0) },
            searchResetRelay.asObservable().map { nil as String? }
        )
        .flatMapLatest { [weak self] text -> Observable<Answer> in
            guard let self else { return .empty() }
            let engine = documentState.runtimeEngine
            guard let text else {
                openQuicklySearch.end()
                return .empty()
            }
            guard !text.isEmpty else {
                openQuicklySearch.end()
                return .just(Answer(searchText: text, entries: [], engine: engine))
            }
            let openQuicklySearch = openQuicklySearch
            let maximumResultCount = Self.maximumResultCount
            return Observable.async {
                Answer(searchText: text, entries: await openQuicklySearch.matches(for: text, limit: maximumResultCount), engine: engine)
            }
        }
        .observeOnMainScheduler()
        .subscribeOnNext { [weak self] answer in
            guard let self, answer.engine === documentState.runtimeEngine else { return }
            let engineName = answer.engine.source.description
            let items = answer.entries.map { entry in
                ContentStartPageItemCellViewModel(item: entry.item, engineName: engineName, engineID: answer.engine.engineID)
            }
            matchesRelay.accept(Matches(searchText: answer.searchText, items: items))
        }
        .disposed(by: rx.disposeBag)

        input.itemOpened.emitOnNext { [weak self] opening in
            guard let self else { return }
            searchResetRelay.accept(())
            open(opening.item.item, in: opening.destination)
        }
        .disposed(by: rx.disposeBag)

        input.dismissed.emitOnNext { [weak self] in
            guard let self else { return }
            searchResetRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        return Output(matches: matchesRelay.asSignal())
    }

    /// Opens `item` in the focused pane: an object in the form a tab shows it already, when one
    /// does (`EditorArea.shownForm(of:)`), an image as its image page.
    private func open(_ item: ContentStartPageItemCellViewModel.Item, in destination: SelectionRoute.Destination) {
        let selectionRouter = documentState.selectionRouter
        switch item {
        case .object(let object):
            selectionRouter.trigger(.open(documentState.editorArea.shownForm(of: object) ?? object, in: destination))
        case .image(let path):
            selectionRouter.trigger(.openImage(path, in: destination))
        }
    }
}

#endif

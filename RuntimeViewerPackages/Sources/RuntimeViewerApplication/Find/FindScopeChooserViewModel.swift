import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// The Find navigator's scope chooser: the indexed images a search can be
/// limited to, picked one or several at a time, and the two scopes that pick
/// no image — every indexed image, and the image the sidebar lists. Each
/// choice goes straight into the document's `FindSession`; there is nothing
/// to apply when the popover closes.
///
/// The list is the engine's indexed images, asked for when the chooser
/// opens, together with every image the corpus coordinator follows and every
/// image already picked: it is there at once, an image indexed while it is
/// open turns up, and a picked image the engine does not have stays listed so
/// it can be dropped.
///
/// Generic over the sidebar level's route, like the Find page that opens it.
public final class FindScopeChooserViewModel<Route: Routable>: ViewModel<Route> {
    @MemberwiseInit(.public)
    public struct Input {
        /// The filter field, as typed: the rows whose image name contains it.
        /// Need not start with a value — until it reports one, every row shows.
        public let filterString: Driver<String>
        public let allIndexedImagesClicked: Signal<Void>
        public let currentImageClicked: Signal<Void>
        /// A row's checkbox: the image to pick, or to drop.
        public let imageToggled: Signal<String>
    }

    public struct Output {
        public let rows: Driver<[FindScopeImageCellViewModel]>
        public let scope: Driver<FindScope>
        /// `Current Image (AppKit)`, or plain `Current Image` while the
        /// sidebar lists none.
        public let currentImageTitle: Driver<String>
        /// Whether the sidebar lists an image, so it can be the scope.
        public let isCurrentImageAvailable: Driver<Bool>
    }

    private let session: FindSession

    /// The rows' cell ViewModels by image, kept so a row on screen keeps its
    /// cell and updates in place. Images that leave the list are dropped.
    private var cellViewModelsByImagePath: [String: FindScopeImageCellViewModel] = [:]

    /// The engine's indexed images; `nil` until it answers.
    @RxObserved
    private var indexedImagePaths: [String]? = nil

    @RxObserved
    private var allRows: [FindScopeImageCellViewModel] = []

    /// The filter field's text as last reported, kept here rather than
    /// combined straight from the input: the field reports only what is typed
    /// into it, and a list waiting on an untouched field would stay empty.
    @RxObserved
    private var filterString: String = ""

    public override init(documentState: DocumentState, router: any Router<Route>) {
        self.session = documentState.findSession
        super.init(documentState: documentState, router: router)
        loadIndexedImagePaths()
    }

    public func transform(_ input: Input) -> Output {
        let session = session
        let scope = session.$query.asDriver().map(\.scope).distinctUntilChanged()

        Observable.combineLatest(
            $indexedImagePaths.asObservable(),
            documentState.findCorpusCoordinator.$buildStatesByImagePath.asObservable(),
            scope.asObservable()
        )
        .observe(on: MainScheduler.instance)
        .subscribeOnNext { [weak self] indexedImagePaths, buildStates, scope in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.allRows = self.makeRows(indexedImagePaths: indexedImagePaths, buildStates: buildStates, scope: scope)
            }
        }
        .disposed(by: rx.disposeBag)

        input.filterString.driveOnNext { [weak self] filterString in
            guard let self else { return }
            self.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.allIndexedImagesClicked.emitOnNext {
            session.update { $0.scope = .allIndexedImages }
        }
        .disposed(by: rx.disposeBag)

        input.currentImageClicked.emitOnNext { [weak self] in
            guard let self, documentState.currentImageNode != nil else { return }
            session.update { $0.scope = .currentImage }
        }
        .disposed(by: rx.disposeBag)

        input.imageToggled.emitOnNext { imagePath in
            session.update { $0.scope = $0.scope.toggling(imagePath) }
        }
        .disposed(by: rx.disposeBag)

        let rows = Driver.combineLatest($allRows.asDriver(), $filterString.asDriver()) { rows, filterString -> [FindScopeImageCellViewModel] in
            let needle = filterString.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return rows }
            return rows.filter { $0.name.range(of: needle, options: [.caseInsensitive]) != nil }
        }

        let currentImagePath = documentState.$currentImageNode.asDriver().map { $0?.path }

        return Output(
            rows: rows,
            scope: scope,
            currentImageTitle: currentImagePath.map { imagePath in
                imagePath.map { "Current Image (\(FindScope.imageName(of: $0)))" } ?? "Current Image"
            },
            isCurrentImageAvailable: currentImagePath.map { $0 != nil }
        )
    }

    // MARK: - Rows

    private func loadIndexedImagePaths() {
        let engine = documentState.runtimeEngine
        Task { [weak self] in
            guard let imagePaths = try? await engine.indexedImagePathList() else { return }
            self?.indexedImagePaths = imagePaths
        }
    }

    private func makeRows(indexedImagePaths: [String]?, buildStates: [String: RuntimeInterfaceCorpusBuildState], scope: FindScope) -> [FindScopeImageCellViewModel] {
        var pickedImagePaths: Set<String> = []
        if case .images(let imagePaths) = scope {
            pickedImagePaths = imagePaths
        }
        let knownImagePaths = Set(indexedImagePaths ?? []).union(buildStates.keys)
        let listedImagePaths = knownImagePaths.union(pickedImagePaths)
        let sortedImagePaths = listedImagePaths.sorted { leftImagePath, rightImagePath in
            let order = FindScope.imageName(of: leftImagePath).localizedCaseInsensitiveCompare(FindScope.imageName(of: rightImagePath))
            return order == .orderedSame ? leftImagePath < rightImagePath : order == .orderedAscending
        }
        let rows = sortedImagePaths.map { imagePath in
            let cellViewModel = cellViewModelsByImagePath[imagePath] ?? FindScopeImageCellViewModel(imagePath: imagePath)
            cellViewModelsByImagePath[imagePath] = cellViewModel
            // Only once the engine has answered can an image be said to be
            // missing from it.
            let isIndexed = indexedImagePaths == nil || knownImagePaths.contains(imagePath)
            cellViewModel.update(isPicked: pickedImagePaths.contains(imagePath), status: Self.status(of: buildStates[imagePath], isIndexed: isIndexed))
            return cellViewModel
        }
        cellViewModelsByImagePath = cellViewModelsByImagePath.filter { listedImagePaths.contains($0.key) }
        return rows
    }

    /// What a row says about its image's corpus.
    static func status(of buildState: RuntimeInterfaceCorpusBuildState?, isIndexed: Bool) -> String {
        switch buildState {
        case .pending:
            "waiting"
        case .building(let progress):
            progress.total > 0 ? "building \(progress.built * 100 / progress.total)%" : "building"
        case .failed:
            "failed"
        case .built:
            ""
        case nil:
            isIndexed ? "" : "not indexed"
        }
    }
}

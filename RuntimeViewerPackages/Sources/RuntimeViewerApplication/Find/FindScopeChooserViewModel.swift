import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// The Find navigator's scope chooser: the sheet the scope menu's Custom
/// Scopes… opens, as Xcode's opens `IDEFindNavigatorScopeChooserController`.
/// It lists the indexed images, any number of which can be selected; OK makes
/// the selection the scope, Cancel leaves the scope as it was. The images the
/// scope holds when the sheet opens start out selected.
///
/// The list is the engine's indexed images, asked for when the chooser
/// opens, together with every image the corpus coordinator follows and every
/// image the scope holds: it is there at once, an image indexed while it is
/// open turns up, and a picked image the engine does not have stays listed so
/// it can be dropped.
///
/// Generic over the sidebar level's route, like the Find page that opens it.
public final class FindScopeChooserViewModel<Route: FindNavigatorRoutable>: ViewModel<Route> {
    @MemberwiseInit(.public)
    public struct Input {
        /// The filter field, as typed: the rows whose image name contains it.
        /// Need not start with a value — until it reports one, every row shows.
        public let filterString: Driver<String>
        /// The images selected in the list, reported when the user changes
        /// the selection — not when the list puts it back after its rows
        /// change. A row the filter hides is not selected by then.
        public let selectionChanged: Signal<Set<String>>
        public let okClicked: Signal<Void>
        public let cancelClicked: Signal<Void>
        /// A double-clicked row, which the list has selected by then: OK, as
        /// `-[IDEFindNavigatorScopeChooserController doubleClickedOutline:]`
        /// completes the sheet.
        public let rowDoubleClicked: Signal<Void>
    }

    public struct Output {
        public let rows: Driver<[FindScopeImageCellViewModel]>
        /// The images to show selected: the scope's when the sheet opens, then
        /// the user's.
        public let selectedImagePaths: Driver<Set<String>>
        /// OK cannot be clicked while nothing is selected.
        public let isOKEnabled: Driver<Bool>
        /// The image to scroll into view, once, when the list is first complete: the first
        /// image the scope holds, in display order.
        public let revealedImagePath: Signal<String>
    }

    private let session: FindSession

    /// The images the scope held when the sheet opened, listed whether or not
    /// the engine has them. Spelled as the engine spells an image — with an iOS
    /// Simulator's root — like the engine's list and the build states they
    /// are compared with.
    private let scopeImagePaths: Set<String>

    /// The rows' cell ViewModels by image, kept so a row on screen keeps its
    /// cell and updates in place. Images that leave the list are dropped.
    private var cellViewModelsByImagePath: [String: FindScopeImageCellViewModel] = [:]

    /// The listed images in display order, and the same images as a set. Sorted again only
    /// when the images listed change — not on every build state change, which comes about
    /// every 16 ms while corpora build.
    private var sortedImagePaths: [String] = []

    private var sortedImagePathSet: Set<String> = []

    /// Whether the scope's first image has been brought into view, which happens once.
    private var hasRevealedSelection = false

    /// Whether the user has changed the selection; after that nothing is revealed.
    private var hasUserChangedSelection = false

    private let revealedImagePathRelay = PublishRelay<String>()

    /// The engine's indexed images, as the engine spells them; `nil` until it answers.
    @RxObserved
    private var indexedImagePaths: [String]? = nil

    @RxObserved
    private var allRows: [FindScopeImageCellViewModel] = []

    /// The filter field's text as last reported, kept here rather than
    /// combined straight from the input: the field reports only what is typed
    /// into it, and a list waiting on an untouched field would stay empty.
    @RxObserved
    private var filterString: String = ""

    /// The images selected in the list: the scope's when the sheet opens,
    /// then whatever the user selects.
    @RxObserved
    private var selectedImagePaths: Set<String>

    public override init(documentState: DocumentState, router: any Router<Route>) {
        self.session = documentState.findSession
        let corpusCoordinator = documentState.findCorpusCoordinator
        let scopeImagePaths = Set(Self.imagePaths(of: documentState.findSession.query.scope, currentImagePath: documentState.currentImageNode?.path).map { corpusCoordinator.canonicalImagePath($0) })
        self.scopeImagePaths = scopeImagePaths
        self.selectedImagePaths = scopeImagePaths
        super.init(documentState: documentState, router: router)
        loadIndexedImagePaths()
    }

    public func transform(_ input: Input) -> Output {
        Observable.combineLatest(
            $indexedImagePaths.asObservable(),
            documentState.findCorpusCoordinator.$buildStatesByImagePath.asObservable()
        )
        .observe(on: MainScheduler.instance)
        .subscribeOnNext { [weak self] indexedImagePaths, buildStates in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.applyListing(indexedImagePaths: indexedImagePaths, buildStates: buildStates)
            }
        }
        .disposed(by: rx.disposeBag)

        input.filterString.driveOnNext { [weak self] filterString in
            guard let self else { return }
            self.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.selectionChanged.emitOnNext { [weak self] imagePaths in
            guard let self else { return }
            hasUserChangedSelection = true
            selectedImagePaths = imagePaths
        }
        .disposed(by: rx.disposeBag)

        Signal.merge(input.okClicked, input.rowDoubleClicked).emitOnNext { [weak self] in
            guard let self else { return }
            applySelection()
        }
        .disposed(by: rx.disposeBag)

        input.cancelClicked.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismissFindScopeChooser)
        }
        .disposed(by: rx.disposeBag)

        let rows = Driver.combineLatest($allRows.asDriver(), $filterString.asDriver()) { rows, filterString -> [FindScopeImageCellViewModel] in
            let needle = filterString.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return rows }
            return rows.filter { $0.name.range(of: needle, options: [.caseInsensitive]) != nil }
        }

        return Output(
            rows: rows,
            selectedImagePaths: $selectedImagePaths.asDriver(),
            isOKEnabled: $selectedImagePaths.asDriver().map { !$0.isEmpty }.distinctUntilChanged(),
            revealedImagePath: revealedImagePathRelay.asSignal()
        )
    }

    /// OK: the selection becomes the scope — an edit of the query, which
    /// Return then searches — and the sheet closes. With nothing selected
    /// there is nothing to apply: Xcode's OK then closes the sheet and changes
    /// nothing, here OK is disabled instead.
    private func applySelection() {
        guard !selectedImagePaths.isEmpty else { return }
        let imagePaths = selectedImagePaths
        session.update { $0.scope = .images(imagePaths) }
        router.trigger(.dismissFindScopeChooser)
    }

    /// The images a scope holds as the sheet opens: the picked ones, the image
    /// the sidebar lists, or none for every indexed image.
    static func imagePaths(of scope: FindScope, currentImagePath: String?) -> Set<String> {
        switch scope {
        case .allIndexedImages:
            []
        case .currentImage:
            currentImagePath.map { [$0] } ?? []
        case .images(let imagePaths):
            imagePaths
        }
    }

    // MARK: - Rows

    private func loadIndexedImagePaths() {
        let engine = documentState.runtimeEngine
        Task { [weak self] in
            guard let imagePaths = try? await engine.indexedImagePathList() else { return }
            // After the await: the ViewModel is not kept alive while the engine answers.
            guard let self else { return }
            // The engine spells its images with a simulator's root already; spelling them
            // again is a no-op, and keeps an engine that does not in step with the scope.
            indexedImagePaths = imagePaths.map { engine.canonicalImagePath($0) }
        }
    }

    private func makeRows(indexedImagePaths: [String]?, buildStates: [String: RuntimeInterfaceCorpusBuildState]) -> [FindScopeImageCellViewModel] {
        let knownImagePaths = Set(indexedImagePaths ?? []).union(buildStates.keys)
        let listedImagePaths = knownImagePaths.union(scopeImagePaths)
        if listedImagePaths != sortedImagePathSet {
            sortedImagePaths = listedImagePaths.sorted { leftImagePath, rightImagePath in
                let order = FindScope.imageName(of: leftImagePath).localizedCaseInsensitiveCompare(FindScope.imageName(of: rightImagePath))
                return order == .orderedSame ? leftImagePath < rightImagePath : order == .orderedAscending
            }
            sortedImagePathSet = listedImagePaths
        }
        let rows = sortedImagePaths.map { imagePath in
            let cellViewModel = cellViewModelsByImagePath[imagePath] ?? FindScopeImageCellViewModel(imagePath: imagePath)
            cellViewModelsByImagePath[imagePath] = cellViewModel
            // Only once the engine has answered can an image be said to be
            // missing from it.
            let isIndexed = indexedImagePaths == nil || knownImagePaths.contains(imagePath)
            cellViewModel.update(status: Self.status(of: buildStates[imagePath], isIndexed: isIndexed))
            return cellViewModel
        }
        cellViewModelsByImagePath = cellViewModelsByImagePath.filter { listedImagePaths.contains($0.key) }
        return rows
    }

    /// The engine's images and their build states, as they change: rows for them, published
    /// again only when the images listed change — a status alone has already reached its row
    /// through the cell's binding — and the scope revealed once the list is complete.
    ///
    /// Internal so a test can stand in for the engine's answer and the coordinator's flushes.
    func applyListing(indexedImagePaths: [String]?, buildStates: [String: RuntimeInterfaceCorpusBuildState]) {
        let rows = makeRows(indexedImagePaths: indexedImagePaths, buildStates: buildStates)
        if rows.map(\.imagePath) != allRows.map(\.imagePath) {
            allRows = rows
        }
        // The list is complete once the engine has listed its images.
        if indexedImagePaths != nil {
            revealSelectionOnce(in: rows)
        }
    }

    /// Brings the scope's first image into view, once: when the engine has listed its images,
    /// for only then is the list complete — as Xcode's chooser reveals the scope's items when
    /// it opens. Nothing is revealed after the user has changed the selection.
    private func revealSelectionOnce(in rows: [FindScopeImageCellViewModel]) {
        guard !hasRevealedSelection, !hasUserChangedSelection else { return }
        hasRevealedSelection = true
        guard let firstSelectedRow = rows.first(where: { selectedImagePaths.contains($0.imagePath) }) else { return }
        revealedImagePathRelay.accept(firstSelectedRow.imagePath)
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

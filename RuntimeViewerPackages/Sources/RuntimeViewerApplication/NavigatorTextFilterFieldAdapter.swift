#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import FoundationToolbox
import RuntimeViewerArchitectures

/// Makes an `NSFilterTokenField` the filter field of a sidebar page, as in Xcode's navigators, and reports what it holds
/// as a `NavigatorTextFilter` — kept out of the view controllers so it can be tested.
///
/// Text turns into tokens when the user ends it with Return, Tab or a comma, or pastes it, by the rules of
/// `NavigatorTextFilter.terms(parsing:)`: `loo` is Contains, `!loo` Does Not Contain, `loo*` Begins With, `*loo` Ends
/// With, and text with any other `*`, `?` or `\` a wildcard pattern. A token's key switches between the first four and
/// the value shows which one it is — `≠ loo`, `loo ⋯`, `⋯ loo` — while a pattern has no menu. Double-clicking a token
/// gives back text that parses into the same token. The tokens and the text not yet turned into tokens all have to hold:
/// the field never offers ANY or ALL, and it completes nothing.
///
/// The filter icon's menu keeps the recent filters, one list for each `RecentFiltersGroup`. A page reads its group's
/// list from `AppDefaults.navigatorFilterFieldStates` when it is made, and saves it whenever the tokens change. The
/// filter in use when the list was saved is not put back but joins the recent filters, as moving on from a filter does.
/// A page whose field is empty takes up the list again when another page of its group saves it; a page with a filter
/// keeps its own list until it is made again, and the page that saves last decides what the next page reads.
@Loggable(.private)
@MainActor
public final class NavigatorTextFilterFieldAdapter: NSObject, NSFilterTokenFieldDelegate {
    /// The pages that keep one list of recent filters between them. The raw values are the keys the lists are saved
    /// under; never change one.
    public enum RecentFiltersGroup: String, CaseIterable, Sendable {
        /// The image list's Directory and Bookmarks pages.
        case imageList
        /// The object list's List and Bookmarks pages.
        case runtimeObjectList
        /// The filter under the Find navigator's results.
        case findResults
        /// The Report navigator.
        case report
    }

    /// The one kind of token. Its empty title leaves the token's key only the arrow of its menu, as in Xcode.
    static let textTokenType = NSFilterTokenType(identifier: "text", title: "")

    static let containsComparisonType = NSFilterTokenComparisonType(identifier: "contains", title: "Contains", exclusion: false)

    static let doesNotContainComparisonType = NSFilterTokenComparisonType(identifier: "doesNotContain", title: "Does Not Contain", exclusion: true)

    /// Marked `loo ⋯`, with Xcode's U+22EF.
    static let beginsWithComparisonType = NSFilterTokenComparisonType(identifier: "beginsWith", title: "Begins With", exclusion: false, valuePrefix: nil, valueSuffix: "\u{22EF}")

    /// Marked `⋯ loo`.
    static let endsWithComparisonType = NSFilterTokenComparisonType(identifier: "endsWith", title: "Ends With", exclusion: false, valuePrefix: "\u{22EF}", valueSuffix: nil)

    /// Not among the field's comparison types, so a pattern's token has no menu: Xcode's navigators do not let a
    /// pattern turn into one of the other four either.
    static let likeComparisonType = NSFilterTokenComparisonType(identifier: "like", title: "Like", exclusion: false)

    private let filterField: NSFilterTokenField

    private let recentFiltersGroup: RecentFiltersGroup

    @Dependency(\.appDefaults)
    private var appDefaults

    private let filterRelay = PublishRelay<NavigatorTextFilter>()

    private let disposeBag = DisposeBag()

    /// The group's state as this page last saved or read it. A state equal to it is neither saved again nor taken up.
    private var lastSyncedState: Data?

    /// The terms of the tokens when the filter last changed: typed text never joins the recent filters, so only a change
    /// of tokens is saved.
    private var lastTokenTerms: [NavigatorTextFilter.Term] = []

    /// Set while the field takes up a saved state, whose changes are not the user's.
    private var isTakingUpSavedState = false

    /// The field's filter each time it changes: at once for a token added, removed or changed from its menu, and once
    /// the user has paused for 0.2 seconds for typing.
    public var filter: Signal<NavigatorTextFilter> {
        filterRelay.asSignal()
    }

    /// The filter the field holds now.
    public var currentFilter: NavigatorTextFilter {
        NavigatorTextFilter(terms: filterField.filterTokens.map(Self.term(for:)), typedText: filterField.editingString)
    }

    public init(filterField: NSFilterTokenField, recentFiltersGroup: RecentFiltersGroup) {
        self.filterField = filterField
        self.recentFiltersGroup = recentFiltersGroup
        super.init()

        filterField.tokenTypes = [Self.textTokenType]
        filterField.defaultTokenType = Self.textTokenType
        filterField.comparisonTypes = [
            Self.containsComparisonType,
            Self.doesNotContainComparisonType,
            Self.beginsWithComparisonType,
            Self.endsWithComparisonType,
        ]
        filterField.defaultComparisonType = Self.containsComparisonType
        filterField.operatorDisplayMode = .never
        filterField.recentFiltersEnabled = true
        filterField.delegate = self

        takeUpSavedState(appDefaults.navigatorFilterFieldStates[recentFiltersGroup.rawValue])

        // Clear Recents, in the filter icon's menu, empties the recent filters without telling the delegate. Apart from a
        // change of tokens, a menu action is the only thing that changes them.
        NotificationCenter.default.rx.notification(NSMenu.didSendActionNotification)
            .asSignal(onErrorSignalWith: .empty())
            .emitOnNextMainActor { [weak self] _ in
                guard let self else { return }
                saveState()
            }
            .disposed(by: disposeBag)

        appDefaults.$navigatorFilterFieldStates
            .asSignal(onErrorSignalWith: .empty())
            .emitOnNextMainActor { [weak self] _ in
                guard let self else { return }
                takeUpStateSavedElsewhere()
            }
            .disposed(by: disposeBag)
    }

    /// Empties the field, tokens and text, for a filter the view model has cleared. The field reports the change as it
    /// reports every change of its tokens.
    public func clear() {
        filterField.filterTokens = []
    }

    // MARK: - NSFilterTokenFieldDelegate

    public func filterTokenFieldDidChangeFilter(_ tokenField: NSFilterTokenField) {
        guard !isTakingUpSavedState else { return }
        let filter = currentFilter
        filterRelay.accept(filter)
        guard filter.terms != lastTokenTerms else { return }
        lastTokenTerms = filter.terms
        saveState()
    }

    public func filterTokenField(_ tokenField: NSFilterTokenField, tokensFor string: String) -> [NSFilterToken]? {
        NavigatorTextFilter.terms(parsing: string).map(Self.token(for:))
    }

    public func filterTokenField(_ tokenField: NSFilterTokenField, editingStringFor token: NSFilterToken) -> String? {
        NavigatorTextFilter.editingString(for: Self.term(for: token))
    }

    // MARK: - Tokens and terms

    static func token(for term: NavigatorTextFilter.Term) -> NSFilterToken {
        NSFilterToken(type: textTokenType, comparisonType: comparisonType(for: term.comparison), value: term.value)
    }

    /// A token from another filter field — pasted from Xcode's console, say — reads as Contains, or as Does Not
    /// Contain when its comparison is an exclusion.
    static func term(for token: NSFilterToken) -> NavigatorTextFilter.Term {
        NavigatorTextFilter.Term(comparison: comparison(for: token.comparisonType), value: token.value)
    }

    private static func comparisonType(for comparison: NavigatorTextFilter.Comparison) -> NSFilterTokenComparisonType {
        switch comparison {
        case .contains: containsComparisonType
        case .doesNotContain: doesNotContainComparisonType
        case .beginsWith: beginsWithComparisonType
        case .endsWith: endsWithComparisonType
        case .like: likeComparisonType
        }
    }

    private static func comparison(for comparisonType: NSFilterTokenComparisonType?) -> NavigatorTextFilter.Comparison {
        guard let comparisonType else { return .contains }
        switch comparisonType.identifier {
        case containsComparisonType.identifier: return .contains
        case doesNotContainComparisonType.identifier: return .doesNotContain
        case beginsWithComparisonType.identifier: return .beginsWith
        case endsWithComparisonType.identifier: return .endsWith
        case likeComparisonType.identifier: return .like
        default: return comparisonType.isExclusion ? .doesNotContain : .contains
        }
    }

    // MARK: - Recent filters

    /// Saves the field's state for the group, unless it is the state the group already has.
    private func saveState() {
        let state = filterField.encodedState
        guard state != lastSyncedState else { return }
        lastSyncedState = state
        appDefaults.navigatorFilterFieldStates[recentFiltersGroup.rawValue] = state
    }

    /// Takes up the recent filters of a saved state, and empties the field rather than put back the filter in use when
    /// the state was saved: emptying it moves that filter to the top of the recent filters.
    private func takeUpSavedState(_ savedState: Data?) {
        lastSyncedState = savedState
        guard let savedState else { return }
        isTakingUpSavedState = true
        defer { isTakingUpSavedState = false }
        do {
            try filterField.restoreState(from: savedState)
        } catch {
            #log(.error, "The recent filters saved for \(self.recentFiltersGroup.rawValue, privacy: .public) could not be read: \(error, privacy: .public)")
            return
        }
        filterField.filterTokens = []
    }

    /// Takes up the group's state when another page of the group has saved one since — only while the field is empty and
    /// not being edited, because taking it up empties the field.
    ///
    /// The store announces each change after it has made it, on its own queue, so an announcement can arrive after this
    /// page has saved again; the state is therefore read afresh, never taken from the announcement.
    private func takeUpStateSavedElsewhere() {
        let savedState = appDefaults.navigatorFilterFieldStates[recentFiltersGroup.rawValue]
        guard savedState != lastSyncedState,
              filterField.filterTokens.isEmpty,
              filterField.editingString.isEmpty,
              filterField.currentEditor() == nil
        else { return }
        takeUpSavedState(savedState)
    }
}

#endif

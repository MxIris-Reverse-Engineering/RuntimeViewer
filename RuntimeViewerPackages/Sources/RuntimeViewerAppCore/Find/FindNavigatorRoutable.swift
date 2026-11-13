import RuntimeViewerArchitectures

/// The routes of a sidebar level that has the Find navigator among its tabs.
///
/// The page is a tab of both sidebar levels, and what it opens is presented
/// by whichever level it is on, so the page asks its own router through these
/// requirements rather than naming either level's route.
public protocol FindNavigatorRoutable: Routable {
    /// The scope chooser, as a sheet on the document window: what the scope
    /// menu's Custom Scopes… opens.
    static var findScopeChooser: Self { get }

    /// Closes the scope chooser.
    static var dismissFindScopeChooser: Self { get }
}

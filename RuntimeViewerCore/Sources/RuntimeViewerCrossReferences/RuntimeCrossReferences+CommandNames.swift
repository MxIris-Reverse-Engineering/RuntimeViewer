import RuntimeViewerCore

/// The cross-reference commands' wire names.
///
/// They keep Core's namespace prefix, as the injection commands do: the
/// assembled string is the wire contract, and every command of every module
/// shares one prefix so that moving a declaration between modules changes no
/// byte that crosses a process boundary.
///
/// Internal, like Core's own: a command name is not API.
extension RuntimeEngine.CommandName {
    /// What one function references: decodes that function only.
    static let crossReferenceCallees = Self("crossReferenceCallees")

    /// Who references a function, a member or a selector, across the images
    /// of a scope. Reports progress, with each image's findings, and is
    /// withdrawn from the serving process when its caller is cancelled.
    static let crossReferenceCallers = Self("crossReferenceCallers")
}

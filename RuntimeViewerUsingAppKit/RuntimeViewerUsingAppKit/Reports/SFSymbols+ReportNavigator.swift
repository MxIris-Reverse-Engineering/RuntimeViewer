import SFSymbols

extension SFSymbols {
    /// The Report navigator's symbol, for its sidebar tab and its menu item: `receipt`, the one
    /// Xcode 26 gives its own Report navigator, which macOS has from 15.2 on. Earlier systems get a
    /// lined page, the closest shape they have.
    static var reportNavigator: SFSymbols {
        if #available(macOS 15.2, *) {
            SFSymbols(systemName: .receipt)
        } else {
            SFSymbols(systemName: .docText)
        }
    }
}

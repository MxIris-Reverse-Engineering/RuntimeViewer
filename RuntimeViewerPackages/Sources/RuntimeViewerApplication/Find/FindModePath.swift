import Foundation

/// A choice one of the mode path's menus offers.
public enum FindModePathChoice: Hashable, Sendable {
    case mode(FindMode)
    case textMatchStyle(FindTextMatchStyle)
    case memberMatchStyle(FindMemberMatchStyle)

    public var title: String {
        switch self {
        case .mode(let mode): mode.title
        case .textMatchStyle(let style): style.title
        case .memberMatchStyle(let style): style.title
        }
    }

    /// Whether the path draws it in the accent colour. Xcode's Find navigator accents every choice
    /// other than the default one — a mode other than Text, a match style other than Containing —
    /// through `-[IDEFindNavigatorQueryParametersController
    /// pathCell:titleColorOfTitleForPathComponentCell:atIndex:]`.
    public var isAccented: Bool {
        switch self {
        case .mode(let mode): mode != .text
        case .textMatchStyle(let style): style != .containing
        case .memberMatchStyle(let style): style != .containing
        }
    }

    /// Whether its menu puts a separator above it: the member match styles' regular expression
    /// follows the four styles Text mode shares, set apart as Text mode sets it apart in a mode of
    /// its own.
    public var isPrecededBySeparator: Bool {
        self == .memberMatchStyle(.regularExpression)
    }

    func apply(to query: inout FindQuery) {
        switch self {
        case .mode(let mode): query.mode = mode
        case .textMatchStyle(let style): query.textMatchStyle = style
        case .memberMatchStyle(let style): query.memberMatchStyle = style
        }
    }
}

/// One component of the mode path, `Find ▸ Text ▸ Containing`.
public struct FindModePathComponent: Hashable, Sendable {
    public let title: String

    /// What the component shows; `nil` for the leading `Find`.
    public let choice: FindModePathChoice?

    /// The choices its menu lists, in menu order. `Find` has none: Xcode's switches between Find
    /// and Replace, and the navigator does not replace.
    public let menuChoices: [FindModePathChoice]

    public var isAccented: Bool {
        choice?.isAccented ?? false
    }

    /// `Find`, the mode, and — in the modes that have one — the match style.
    static func path(for query: FindQuery) -> [FindModePathComponent] {
        var path = [
            FindModePathComponent(title: "Find", choice: nil, menuChoices: []),
            FindModePathComponent(choice: .mode(query.mode), menuChoices: FindMode.allCases.map(FindModePathChoice.mode)),
        ]
        if query.mode.hasTextMatchStyles {
            path.append(FindModePathComponent(
                choice: .textMatchStyle(query.textMatchStyle),
                menuChoices: FindTextMatchStyle.allCases.map(FindModePathChoice.textMatchStyle)
            ))
        } else if query.mode.hasMemberKinds {
            path.append(FindModePathComponent(
                choice: .memberMatchStyle(query.memberMatchStyle),
                menuChoices: FindMemberMatchStyle.allCases.map(FindModePathChoice.memberMatchStyle)
            ))
        }
        return path
    }

    private init(title: String, choice: FindModePathChoice?, menuChoices: [FindModePathChoice]) {
        self.title = title
        self.choice = choice
        self.menuChoices = menuChoices
    }

    private init(choice: FindModePathChoice, menuChoices: [FindModePathChoice]) {
        self.init(title: choice.title, choice: choice, menuChoices: menuChoices)
    }
}

import Foundation

/// A small labelled tag at the trailing end of a runtime-object row, after the title.
///
/// Tags are part of `RuntimeObjectCellAppearance`, so they are published with the rest of what a
/// row shows. A clickable tag reports its `identifier` to the list's view controller, which hands
/// it to the list's view model together with the row; a tag that is not clickable leaves the
/// click to the row.
public struct RuntimeObjectCellTag: Hashable, Sendable {
    public enum Identifier: Hashable, Sendable {
        /// The row's object has private declarations (`RuntimeObject.privateDeclarations`); the
        /// tag's popover shows their discriminators and the source files they were derived from.
        case privateDeclaration
    }

    public let identifier: Identifier

    public let title: String

    public let toolTip: String?

    public let isClickable: Bool

    public init(identifier: Identifier, title: String, toolTip: String?, isClickable: Bool) {
        self.identifier = identifier
        self.title = title
        self.toolTip = toolTip
        self.isClickable = isClickable
    }

    /// `Private`, after the name of a type that runs through a private declaration.
    public static func privateDeclaration(isClickable: Bool) -> RuntimeObjectCellTag {
        RuntimeObjectCellTag(
            identifier: .privateDeclaration,
            title: "Private",
            toolTip: isClickable ? "Show Private Declaration Details" : "Private Declaration",
            isClickable: isClickable
        )
    }
}

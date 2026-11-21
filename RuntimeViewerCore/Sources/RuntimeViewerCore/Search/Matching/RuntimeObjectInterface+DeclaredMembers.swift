import Foundation
import Semantic

extension RuntimeObjectInterface {
    /// The member each line declares, by 1-based line number, read the way
    /// the Find corpus locates members on their lines
    /// (`RuntimeMemberDeclarationLocator`). A member of a nested type printed
    /// inside this one is left out: it is not this object's.
    public func declaredMembersByLineNumber() -> [Int: RuntimeDeclaredMember] {
        let isSwift: Bool
        switch object.kind {
        case .swift: isSwift = true
        // No rule of the locator matches a C++ declaration, so a C++
        // interface declares no member it can find.
        case .objc, .c, .cPlusPlus: isSwift = false
        }
        return RuntimeMemberDeclarationLocator.declaredMembersByLine(in: interfaceString, isSwift: isSwift)
    }
}

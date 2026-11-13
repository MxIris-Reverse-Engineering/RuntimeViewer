import Foundation
import RuntimeViewerArchitectures

/// One image row of the Find navigator's scope chooser: the image's name and
/// where its corpus stands. Whether the row is selected is the list's
/// selection, not the row's.
///
/// Kept per image while the chooser is open and updated in place, so a row's
/// status changes without the list reloading.
public final class FindScopeImageCellViewModel: NSObject, @unchecked Sendable {
    public let imagePath: String

    /// The image's file name, `Foundation` or `libobjc.A.dylib`.
    public let name: String

    /// `waiting`, `building 37%`, `failed` or `not indexed`; empty once the
    /// image is searchable, and while there is nothing to say.
    @RxObserved
    public private(set) var status: String = ""

    init(imagePath: String) {
        self.imagePath = imagePath
        self.name = FindScope.imageName(of: imagePath)
        super.init()
    }

    /// Touches the status only when it changes, so the cell's binding fires
    /// for real changes only.
    func update(status: String) {
        if self.status != status {
            self.status = status
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension FindScopeImageCellViewModel: Differentiable {
    public var differenceIdentifier: String { imagePath }

    /// What a row shows changes through the cell's bindings, so a row
    /// reloads only when it stands for another cell ViewModel.
    public func isContentEqual(to source: FindScopeImageCellViewModel) -> Bool {
        self === source
    }
}
#endif

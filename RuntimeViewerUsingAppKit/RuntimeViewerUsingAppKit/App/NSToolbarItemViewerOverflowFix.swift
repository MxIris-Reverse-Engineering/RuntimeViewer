import AppKit
import ObjectiveC.runtime

// On macOS 15, NSToolbar's overflow chevron stays visible (and lists hidden items)
// because -[NSToolbarItemViewer participatesInOverflow] only checks isSpace and
// ignores the parent item's hidden state. macOS 26 fixed it by also checking
// itemPosition == 3, the hidden marker that -[NSToolbarItem _updateItemPosition]
// already writes on macOS 15. We replicate macOS 26's check at app launch.
enum NSToolbarItemViewerOverflowFix {
    private static let hiddenItemPosition: Int = 3

    static func install() {
        guard #unavailable(macOS 26.0) else { return }
        guard let viewerClass = NSClassFromString("NSToolbarItemViewer") else { return }
        let participatesSelector = NSSelectorFromString("participatesInOverflow")
        guard let participatesMethod = class_getInstanceMethod(viewerClass, participatesSelector) else { return }

        typealias ParticipatesIMP = @convention(c) (AnyObject, Selector) -> Bool
        let originalIMP = method_getImplementation(participatesMethod)
        let originalParticipates = unsafeBitCast(originalIMP, to: ParticipatesIMP.self)

        let itemPositionSelector = NSSelectorFromString("itemPosition")
        typealias ItemPositionIMP = @convention(c) (AnyObject, Selector) -> Int

        let replacement: @convention(block) (AnyObject) -> Bool = { receiver in
            if let itemPositionMethod = class_getInstanceMethod(type(of: receiver), itemPositionSelector) {
                let itemPosition = unsafeBitCast(method_getImplementation(itemPositionMethod), to: ItemPositionIMP.self)
                if itemPosition(receiver, itemPositionSelector) == hiddenItemPosition {
                    return false
                }
            }
            return originalParticipates(receiver, participatesSelector)
        }
        let replacementIMP = imp_implementationWithBlock(replacement)
        method_setImplementation(participatesMethod, replacementIMP)
    }
}

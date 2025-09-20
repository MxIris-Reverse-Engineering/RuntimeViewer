import AppKit

// Fix UXKit Exception
#if canImport(UXKit)
extension NSViewController {
    @objc func transitionCoordinator() -> Any? {
        return nil
    }

    @objc func _ancestorViewControllerOfClass(_ class: Any?) -> Any? {
        return nil
    }
}
#endif

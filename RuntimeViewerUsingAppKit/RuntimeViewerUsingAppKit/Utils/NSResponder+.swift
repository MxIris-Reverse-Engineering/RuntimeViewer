import AppKit

extension NSResponder {
    func printResponderChain() {
        print("--- Printing Responder Chain starting from \(type(of: self)) ---")
        var current: NSResponder? = self
        var index = 0
        while let responder = current {
            print("  [\(index)]: \(responder)")
            current = responder.nextResponder
            index += 1
        }
        print("--- End of Responder Chain ---")
    }
}

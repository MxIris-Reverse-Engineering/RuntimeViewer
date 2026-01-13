import Foundation

@objc(AppKitPlugin)
protocol AppKitPlugin: NSObjectProtocol {
    init()
    func launch()
}

import UIKit

extension UIViewController {
    convenience init(view: UIView) {
        self.init()
        self.view = view
    }
}

extension UIImage {
    static func image(withColor color: UIColor, size: CGSize = CGSize(width: 1, height: 1)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

#if os(tvOS)
extension UIColor {
    static var systemBackground: UIColor {
        .init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? "#FFFFFFFF".uiColor : "#000000FF".uiColor
        }
    }

    static var secondarySystemBackground: UIColor {
        .init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? "#F2F2F7FF".uiColor : "#1C1C1EFF".uiColor
        }
    }
}

extension UISearchBar {
    static func make() -> UISearchBar {
        let UISearchBarClass = NSClassFromString("UISearchBar") as! UIView.Type
        return UISearchBarClass.init(frame: .zero) as! UISearchBar
    }
}

#endif

#if os(tvOS)
import RxSwift
import RxCocoa

extension Reactive where Base: UIButton {
    /// Reactive wrapper for target action pattern on `self`.
    public var tap: ControlEvent<Void> {
        primaryAction
    }
}
#endif

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
#endif

#if os(iOS) || os(tvOS)
import UIKit.UIGeometry
#endif

protocol Then {}

extension Then {
    /// Makes it available to set properties with closures just after initializing and copying the value types.
    ///
    ///     let frame = CGRect().with {
    ///       $0.origin.x = 10
    ///       $0.size.width = 100
    ///     }
    @inlinable
    func with<E: Error>(_ block: (inout Self) throws(E) -> Void) throws(E) -> Self {
        var copy = self
        try block(&copy)
        return copy
    }

    /// Makes it available to execute something with closures.
    ///
    ///     UserDefaults.standard.do {
    ///       $0.set("devxoul", forKey: "username")
    ///       $0.set("devxoul@gmail.com", forKey: "email")
    ///       $0.synchronize()
    ///     }
    @inlinable
    func `do`<E: Error>(_ block: (Self) throws(E) -> Void) throws(E) {
        try block(self)
    }
}

extension Then where Self: AnyObject {
    /// Makes it available to set properties with closures just after initializing.
    ///
    ///     let label = UILabel().then {
    ///       $0.textAlignment = .center
    ///       $0.textColor = UIColor.black
    ///       $0.text = "Hello, World!"
    ///     }
    @inlinable
    @discardableResult
    func then<E: Error>(_ block: (Self) throws(E) -> Void) throws(E) -> Self {
        try block(self)
        return self
    }
}

extension Then {
    @inlinable
    func `as`<T, E: Error>(_ transform: (Self) throws(E) -> T) throws(E) -> T {
        try transform(self)
    }
}

extension NSObject: Then {}

extension CGPoint: Then {}
extension CGRect: Then {}
extension CGSize: Then {}
extension CGVector: Then {}

extension Array: Then {}
extension Dictionary: Then {}
extension Set: Then {}
extension JSONDecoder: Then {}
extension JSONEncoder: Then {}

#if os(macOS)
extension NSEdgeInsets: Then {}
extension NSRectEdge: Then {}
extension NSDirectionalRectEdge: Then {}
extension NSDirectionalEdgeInsets: Then {}
@available(macOS 15.0, *)
extension NSHorizontalDirection: Then {}
@available(macOS 15.0, *)
extension NSHorizontalDirection.Set: Then {}
@available(macOS 15.0, *)
extension NSVerticalDirection: Then {}
@available(macOS 15.0, *)
extension NSVerticalDirection.Set: Then {}
@available(macOS 15.0, *)
extension NSSuggestionItem: Then {}
@available(macOS 15.0, *)
extension NSSuggestionItemResponse: Then {}
@available(macOS 15.0, *)
extension NSSuggestionItemResponse.Highlight: Then {}
@available(macOS 15.0, *)
extension NSSuggestionItemResponse.Phase: Then {}
@available(macOS 15.0, *)
extension NSSuggestionItemSection: Then {}
@available(macOS 26.0, *)
extension NSItemBadge: Then {}
@available(macOS 26.0, *)
extension NSView.LayoutRegion: Then {}
#endif

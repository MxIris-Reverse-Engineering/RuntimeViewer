import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import DifferenceKit
#endif

/// Lightweight value wrapper that lifts any `Hashable` model into a row
/// element suitable for `tableView.rx.items` / `outlineView.rx.nodes`, so
/// per-row `cellViewModel` instances can be constructed lazily inside the
/// cell builder closure rather than eagerly at data-source init time.
///
/// ## When to use
///
/// - The data set is large (N >= ~1k) and eager `cellViewModel`
///   construction shows up as a main-thread bottleneck in Instruments.
/// - The `cellViewModel`'s state is **fully determined at init time** from
///   the model alone and does **not** subscribe to any ongoing state
///   (no `@Observed` properties that mutate after init, no Rx pipelines
///   fed by external sources, no async loading).
///
/// ## When NOT to use
///
/// - The `cellViewModel` owns long-lived subscriptions or mutable
///   `@Observed` state that updates over the row's lifetime — e.g.
///   Sidebar's filter-aware attributed name, Inspector's async metadata
///   loading. Lazy reconstruction discards subscription identity;
///   downstream observers attached to the previous instance get dropped
///   on the floor.
/// - The model has fewer than ~hundreds of rows. Eager `cellViewModel`
///   construction is already cheap; the wrapper just adds indirection.
/// - You need per-row UI state that cannot be derived from the model
///   (expanded/collapsed flag, multi-select checkmark, drag preview).
///   Build a local struct conforming to `Differentiable` directly instead
///   of extending this wrapper — adding mutable fields here would break
///   the identity invariant for every other consumer.
///
/// ## Identity contract
///
/// `differenceIdentifier == model` and `isContentEqual` compares the
/// underlying model by `==`. Two `DifferentiableBox<Model>` values are
/// considered the same row iff their models are `==`-equal. If `Model`
/// is a value type whose equality includes presentation-only fields,
/// those fields will spuriously trigger `Changeset` updates. Choose
/// `Model`'s `Equatable` / `Hashable` carefully — typically a domain
/// primary key.
///
/// ## Sendable
///
/// `DifferentiableBox<Model>` is `Sendable` iff `Model: Sendable`. The
/// conformance is auto-synthesized — value-type `struct` containing a
/// single `let model: Model`, so any non-`Sendable` reference-type
/// model (an `NSObject` subclass without `@unchecked Sendable`, for
/// example) makes the box itself non-`Sendable`. The box is safe to
/// cross actor boundaries whenever the underlying model is.
public struct DifferentiableBox<Model: Hashable>: Hashable {
    public let model: Model

    public init(_ model: Model) {
        self.model = model
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension DifferentiableBox: Differentiable {
    public var differenceIdentifier: Model { model }

    public func isContentEqual(to source: DifferentiableBox<Model>) -> Bool {
        model == source.model
    }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import RxAppKit
#endif

import RuntimeViewerCore

/// A sidebar section that groups runtime objects sharing a single
/// `RuntimeObjectKind`. This is the "Section model" that turns the previously
/// flat, single-layer runtime-object list into kind-grouped sections — e.g.
/// "Objective-C Class", "Objective-C Protocol", "Swift Class", "Swift Enum",
/// "Swift Class Extension", …
///
/// The header title is derived from `kind.description`. Sections sort by `kind`
/// (`RuntimeObjectKind` is `Comparable`), and only non-empty sections are ever
/// produced (see `SidebarRuntimeObjectViewModel.makeSections(from:)`).
///
/// ## Identity contract
///
/// `objects` is carried as *payload*, but the section's identity is its `kind`
/// alone: `Equatable` / `Hashable` compare only `kind`. This is deliberate and
/// important — the section model is used directly as an outline-view item
/// (AppKit) and as a diffable section identifier (UIKit), both of which key on
/// `Hashable`. Keying identity on `kind` keeps a section stable (and the outline
/// view keeps its expansion state) when its contained objects change underneath
/// it. Two sections never share a kind, so equality-by-kind stays unambiguous.
///
/// Because equality ignores `objects`, never feed a stream of
/// `[SidebarRuntimeObjectSection]` through `distinctUntilChanged` — a
/// content-only change (same kinds, different objects) would be swallowed.
public struct SidebarRuntimeObjectSection: Sendable {
    public let kind: RuntimeObjectKind

    public let objects: [SidebarRuntimeObjectCellViewModel]

    public var title: String { kind.description }

    public init(kind: RuntimeObjectKind, objects: [SidebarRuntimeObjectCellViewModel]) {
        self.kind = kind
        self.objects = objects
    }
}

extension SidebarRuntimeObjectSection: Hashable {
    public static func == (lhs: SidebarRuntimeObjectSection, rhs: SidebarRuntimeObjectSection) -> Bool {
        lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SidebarRuntimeObjectSection: Differentiable {
    public var differenceIdentifier: RuntimeObjectKind { kind }

    public func isContentEqual(to source: SidebarRuntimeObjectSection) -> Bool {
        // The header row renders only `title`, which is fully determined by
        // `kind`; the object count surfaces through the section's elements, not
        // the header itself.
        kind == source.kind
    }
}

#endif

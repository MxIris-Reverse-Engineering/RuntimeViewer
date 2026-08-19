import Foundation
import ObjectiveC

/// Lets a type *reference* reach ``SemanticNodeTypeAdjuster`` instead of being settled as a
/// declaration before the adjuster is ever asked.
///
/// `SourceModelSyntaxTokenProvider.adjustNodeType(for:sourceModel:)` runs a check of its own
/// first, and returns early when it passes:
///
/// ```
/// if item.parent.nodeType == "xcode.syntax.name.type",
///    sourceModel.isDeclarationOrDefinitionAtLocation(item.range.location) {
///     item.setNodeType("xcode.syntax.declaration.type")
///     item.setNeedsAdjustNodeType(false)
///     return                                    // the adjuster is never consulted
/// }
/// ```
///
/// Objective-C's language specification gives both names in `@interface NSView : NSResponder`
/// the same rule — `xcode.lang.objc.classname`, typed `xcode.syntax.name.type` — and the whole
/// `@interface … @end` block counts as a declaration, so the superclass passes the check and is
/// coloured as a declaration alongside the class being declared. Nothing downstream can tell
/// them apart afterwards: to the parse they are the same kind of node.
///
/// The check is there to guess what an editor with no semantic information cannot know.
/// RuntimeViewer does know, having rendered the interface from runtime metadata, so for the
/// ranges it labels as references the guess is answered `false`, the node reaches the adjuster,
/// and it is retyped from what the generator recorded. Declarations are left to the original
/// implementation and keep behaving as before.
///
/// **Scope, verified against Xcode 26.6**: `-isDeclarationOrDefinitionAtLocation:` has exactly
/// one caller across `SourceModel`, `SourceModelSupport`, `SourceEditor`,
/// `SourceEditorSwiftSupport`, `DVTSourceEditor` and `IDESourceEditor` — the node type
/// adjustment above — and the `-isItemDeclarationOrDefinition:` it forwards to has no other
/// caller either. Navigation, folding and the structure outline do not read it.
///
/// If a future Xcode renames or drops the method, `install()` finds nothing to replace and
/// leaves the editor exactly as it is today.
enum SourceModelDeclarationShortCircuitOverride {
    private static let selector = Selector(("isDeclarationOrDefinitionAtLocation:"))

    private nonisolated(unsafe) static var originalImplementation: (@convention(c) (AnyObject, Selector, Int) -> ObjCBool)?

    /// Idempotent — every bridge instance may call it, only the first does anything.
    static func install() {
        _ = installOnce
    }

    private static let installOnce: Void = {
        guard let sourceModelClass = NSClassFromString("SMSourceModel"),
              let method = class_getInstanceMethod(sourceModelClass, selector)
        else { return }

        // Read the original before installing the replacement, so a parse already running on
        // another thread cannot land between the two and find nothing to fall back to.
        originalImplementation = unsafeBitCast(
            method_getImplementation(method),
            to: (@convention(c) (AnyObject, Selector, Int) -> ObjCBool).self
        )

        let replacement: @convention(block) (AnyObject, Int) -> ObjCBool = { sourceModel, location in
            if SemanticNodeTypeAdjuster.isTypeReferenceLocation(location) {
                return false
            }
            guard let originalImplementation else { return false }
            return originalImplementation(sourceModel, selector, location)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }()
}

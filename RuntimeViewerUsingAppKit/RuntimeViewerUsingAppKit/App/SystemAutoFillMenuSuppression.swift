import AppKit

// Takes AppKit's "AutoFill" submenu out of every contextual menu, and out of the Edit menu.
//
// Nothing in this app asks for it: contextual menus here act on a read-only interface listing,
// and the few text fields that exist are filters and settings, not sign-in forms. The submenu
// it opens — Contact… / Passwords… / Credit Card… — offers to type a password into a class
// dump.
//
// It cannot be removed from the menu after the fact. AppKit inserts the contextual one as the
// menu opens, from `NSContextMenuStartPluginsForMenuRef2`, which registers a set of menu
// updaters against the Carbon menu ref — well after `SourceEditorView.contextMenu()` has handed
// the menu to its item provider. The only seam is the condition guarding it,
// `NSAutoFillSystemInsertMenuEnabled()`, and that reads a user default.
//
// Registered rather than set: the value goes into the registration domain, which the
// `objectForKey:` inside `_NSGetBoolAppConfig` reads like any other, without writing anything
// to the user's preferences.
//
// ## Why this runs from `AppDelegate.init`
//
// **`applicationDidFinishLaunching` is too late — measured, not assumed.** The key has two
// readers, and the first one runs during startup:
//
// ```
// NSApplication.setMainMenu: / finishLaunching / _postDidFinishNotification
//     → _customizeMainMenu → _addTextInputMenuItems:   ← reads it here
// ```
//
// That is where the Edit menu gets its AutoFill / Emoji & Symbols / Dictation items, and
// `_NSGetBoolAppConfig` caches its answer in a static byte on first read and never consults the
// defaults again. `AppDelegate` is unarchived from the main nib, and a nib instantiates its
// objects before it connects their outlets — `NSApplication.mainMenu` among them — so `init`
// lands before that read while any delegate callback lands after it.
//
// Measured by whether AppKit put its item into the Edit menu, which is gated on the same key:
//
// | registration site | AutoFill in Edit menu |
// |---|---|
// | `AppDelegate.init` | absent |
// | none (control) | present |
// | `applicationDidFinishLaunching` | present |
//
// **Do not move this call into a lifecycle method.** It silently stops working there, and the
// only symptom is the menu item coming back.
//
// ## Turning off the rest of that group
//
// AutoFill is one of four things AppKit appends to contextual menus, all behind one outer
// condition:
//
// ```
// if NSAddServicesToContextMenus() {            // default YES — the whole group
//     Services, Continuity
//     if NSAutoFillSystemInsertMenuEnabled() {  // default YES — AutoFill alone, what we set
//         AutoFill
//     }
//     Writing Tools, separator
// }
// ```
//
// Registering the outer key `false` removes **Services, Continuity, AutoFill and Writing Tools
// together**, leaving a contextual menu with only this app's own items and Copy/Paste:
//
// ```swift
// UserDefaults.standard.register(defaults: ["NSAddServicesToContextMenus": false])
// ```
//
// That one has no early reader — its only callers are `NSContextMenuStartPluginsForMenuRef2`
// and its `…End…` counterpart, both of which run when a contextual menu opens — so unlike this
// key it also works from `applicationDidFinishLaunching`. It does not touch the Edit menu.
// Writing Tools has no separate switch of its own; taking it out means taking the group.
//
// Both keys are undocumented; they were read out of AppKit (macOS 26.5.2).
enum SystemAutoFillMenuSuppression {
    private static let autoFillDefaultsKey = "NSAutoFillSystemInsertMenuEnabled"

    static func install() {
        UserDefaults.standard.register(defaults: [autoFillDefaultsKey: false])
    }
}

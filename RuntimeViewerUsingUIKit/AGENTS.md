# AGENTS.md — the iOS-family apps

`RuntimeViewerUsingUIKit.xcodeproj` builds three apps from one source folder: `RuntimeViewerUsingUIKit`
(iOS), `RuntimeViewerUsingUIKit-JB` (the jailbroken iOS variant) and `RuntimeViewerUsingVision`
(visionOS). `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/` is a synchronized folder shared by all three,
so a file added there joins every target and no rule file may go in it — they go here.

## Launch order

`AppDelegate.application(_:didFinishLaunchingWithOptions:)` sets things up in an order that matters, and
says why at each step:

1. `settingsLifecycleController.loadOnLaunch()` — the settings, before anything reads one; then
   `appearanceController.start()`, which needs them.
2. `InjectionServiceRegistrar.registerIfAvailable()` and `RuntimeCrossReferences.install()` — the
   command extensions, before any engine exists (root `AGENTS.md`, *Injection commands*).
3. `SuspensionPreventionRegistrar.registerIfAvailable()`.
4. `.local`, then the engine manager, which advertises this device to a Mac.
5. `runtimeEngineManagerSettingsFollower.startFollowing()` — the settings the manager takes, as on the
   Mac. Not in the settings lifecycle controller, which runs first: reading the manager there would bring
   the engines up before the command extensions are registered.
6. `fileController.start()` — lets a file read from disk go thirty seconds after its last window left.

A new step goes where its comment can say what it has to come before.

## Windows and their documents

Every window — a `UIScene` — has a `DocumentSession` (RuntimeViewerAppCore), the type the macOS app's
`Document` holds too: it owns the window's `DocumentState` and opens before anything binds, joining the
engine's background work, and closes when the window goes. **Never make a `DocumentState` in the app, and
never call `startBackgroundWork()` or `documentWillClose()` yourself.**

- **`DocumentSessionRegistry` hands each scene its session**, by `UISceneSession.persistentIdentifier`:
  `SceneDelegate` asks for it as the scene connects. A window keeps its session while the process lives —
  the system disconnects background scenes to save memory, and one connecting again finds its document as
  it left it — and the session closes only when the user closes the window
  (`application(_:didDiscardSceneSessions:)` → `discardSessions(forWindows:)`).
- **A window opened for a file** is requested with the file's engine reserved in the registry under a
  request identifier, which travels in the scene's `NSUserActivity` (`FileWindowActivity`, of the type
  `<bundle identifier>.fileWindow` each `Info.plist` lists under `NSUserActivityTypes`). A window whose
  request is unknown — one the system restores after a relaunch, or the New Window an iPad offers — starts
  on this device: nothing of a window is restored, as on the Mac.
- iOS and the jailbroken app support multiple scenes (`UIApplicationSupportsMultipleScenes`), as visionOS
  always did; an iPhone still shows one.

## Opening files

The apps open Mach-O files, bundles, folders and dyld shared caches from disk through `FileController`
(`App/FileController.swift`), the counterpart of the macOS app's: the open button beside the gear on the
sidebar's root page (a document picker), Open Path… on the jailbroken app, and Open In from Files
(`CFBundleDocumentTypes` for `public.data` and `public.directory`, opened in place).

- **The shared part is RuntimeViewerAppCore's `RuntimeFileOpener`**, the one the Mac's File › Open… uses:
  it picks the dependency cache — this device's own for a file built for this platform, the file alone when
  that cache cannot be opened — and reads the file **in this process**, so an unreadable file throws before
  any window opens, and `FileController` says why over the window it was opened from. The opener holds a
  security-scoped URL's access while the engine reads the file, and `RuntimeFileEngineParking` takes the
  engine off the list thirty seconds after its last window left, ending the access.
- **Where a file opens**: in a window of its own where the device shows several
  (`UIApplication.supportsMultipleScenes`: iPad, visionOS), and on an iPhone over the window it was opened
  from, full screen, held by `FileController`. A file window's sidebar has a close button
  (`MainCoordinator(documentState:isFileWindow:)`); it destroys the scene, or on an iPhone dismisses the
  stacked window back to the one under it.
- **Open Path… exists where the app has no container** (`FileController.opensAbsolutePaths`, decided at
  run time from the home directory — the jailbroken variant): a document picker cannot reach the system's
  paths or another app's binaries. No compile-time flag decides it.

Background: `Documentations/Evolutions/0102-window-model-on-ios.md`.

## Settings

The apps' `SettingsLifecycleController` (`App/SettingsLifecycleController.swift`) is the counterpart of
the macOS app's:

- **It loads with `loadSynchronously()`, not `load()`.** The first scene connects as soon as
  `didFinishLaunching` returns and reads settings as it does, possibly before a task started there has
  run; the asynchronous load would leave it with the defaults, and an edit made before the load finished
  would write them back.
- **It flushes on the app-level `UIApplication.didEnterBackgroundNotification` and
  `willTerminateNotification`.** iOS has no `applicationShouldTerminate`, a suspended app can be killed
  without another callback, and a scene's `sceneDidEnterBackground(_:)` fires while other scenes can still
  be in front.
- The file is `Library/Application Support/RuntimeViewer[-Debug]/settings.json` in the app's container.
  The jailbroken variant has no container (`no-container`, `no-sandbox`), so its file is under
  `/var/mobile/Library/Application Support/RuntimeViewer[-Debug]/`. The derived data of the Find corpora
  is not enabled here: the apps have no Find yet.

Background: `Documentations/Evolutions/0100-settings-storage-on-ios.md`.

## Settings screen and appearance

- **The gear on the sidebar's root page opens the settings.** `SidebarCoordinator` puts it there and
  tells `MainCoordinator` through `SidebarCoordinatorDelegate`; `MainRoute.settings` presents
  `RuntimeViewerSettingsUI`'s `SettingsViewController` as a form sheet, a fresh one each time.
- **The pages are the macOS ones** — Appearance (the General page's appearance section,
  `AppearanceSettingsSection`), Theme, Transformer — hosted by UIFoundation's iOS
  `SettingsViewController`. A page joins the list when what it configures works on iOS; a page that
  reaches for AppKit gets a UIKit branch, as the Transformer page's template editor has
  (`TokenTemplateTextField+UIKit.swift`, with the placeholder rules shared with AppKit in
  `TokenTemplatePlaceholder` and pinned by `TokenTemplatePlaceholderTests`).
- **Where iOS has its own idiom, the page follows iOS.** The Appearance section draws iOS Settings ›
  Display & Brightness — the light and dark devices (`DeviceAppearancePicker`, the images exported
  from iOS 27 as `AppearanceLight-iOS` / `AppearanceDark-iOS`) and a Match System switch in place of
  the System choice — after the recipe reversed from `DBSDeviceAppearanceOptionView`, recorded in the
  proposal's decision log. The Theme page's font size shows its value in the stepper's label, since the
  iOS `Stepper` has no field.
- **A page has to fit an iPhone's width.** The Transformer editors lay their rows out through
  `EditorGrid` / `EditorRow` (a label column on macOS, each label above its control on iOS); chips and
  buttons that can outgrow a row go in `FlowLayout`. The UIKit template field sizes itself in
  `sizeThatFits` to the width it is offered: give it no fixed height, and never leave a non-scrolling
  `UITextView` to its intrinsic size, which is its text on one line.
- **`AppearanceController` applies the Appearance setting to every window** through
  `overrideUserInterfaceStyle`: all connected scenes when the setting changes, and `SceneDelegate`
  applies it to each window it creates.
- **The content pane follows the settings' theme** (`resolvedThemeStream`, as on macOS), background
  included.

Background: `Documentations/Evolutions/0101-settings-screen-on-ios.md`.

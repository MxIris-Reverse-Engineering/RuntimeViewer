# AGENTS.md — the iOS-family apps

`RuntimeViewerUsingUIKit.xcodeproj` builds three apps from one source folder: `RuntimeViewerUsingUIKit`
(iOS), `RuntimeViewerUsingUIKit-JB` (the jailbroken iOS variant) and `RuntimeViewerUsingVision`
(visionOS). `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/` is a synchronized folder shared by all three,
so a file added there joins every target and no rule file may go in it — they go here.

## Launch order

`AppDelegate.application(_:didFinishLaunchingWithOptions:)` sets things up in an order that matters, and
says why at each step:

1. `settingsLifecycleController.loadOnLaunch()` — the settings, before anything reads one.
2. `InjectionServiceRegistrar.registerIfAvailable()` and `RuntimeCrossReferences.install()` — the
   command extensions, before any engine exists (root `AGENTS.md`, *Injection commands*).
3. `SuspensionPreventionRegistrar.registerIfAvailable()`.
4. `.local`, then the engine manager, which advertises this device to a Mac.

A new step goes where its comment can say what it has to come before.

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
  The derived data of the Find corpora is not enabled here: the apps have no Find yet.

Background: `Documentations/Evolutions/0100-settings-storage-on-ios.md`.

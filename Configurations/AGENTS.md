# AGENTS.md — build settings

Every target's build settings live here, never in the project files (root `AGENTS.md`, *Build Settings
and the Tuist Development Workspace*): `Configurations/<target>/` holds a `Shared.xcconfig` plus a file per
configuration that has values of its own; the daemon's are in `LaunchDaemon/`, the AppKit project level's
in `RuntimeViewerUsingAppKitProject/`. Two values are written once for everyone:

- `Version.xcconfig` — `MARKETING_VERSION`, the one place a release bumps (the `ArchiveScript.sh` check
  against `--version-tag` reads it back);
- `ServiceName/<configuration>.xcconfig` — `RUNTIME_VIEWER_SERVICE_NAME`, see below.

The app icon names are picked in `RuntimeViewerUsingAppKit/Shared.xcconfig` and
`RuntimeViewerCatalystHelper/Shared.xcconfig`; read `Resources/AGENTS.md` before changing them.

## Embedded non-macOS products

The app embeds three products that are not macOS, and all three are ordinary target dependencies of the
app: building `RuntimeViewer macOS` builds them in the app's configuration, and the app's copy phases
embed the built products.

| Product | Target | Platform settings | Built into | Embedded by, at |
|---------|--------|-------------------|------------|-----------------|
| Catalyst service | `RuntimeViewerCatalystService` | `SDKROOT = macosx`, `SDK_VARIANT = iosmac` | `<configuration>-maccatalyst/` | `Embed XPC Services`, `Contents/XPCServices/` |
| Catalyst helper | `RuntimeViewerCatalystHelper` | `SDKROOT = macosx`, `SDK_VARIANT = iosmac` | `<configuration>-maccatalyst/` | `Embed Catalyst Helpers`, `Contents/Applications/` |
| Simulator payload | `RuntimeViewerSimulatorServer` (in `RuntimeViewerServer.xcodeproj`) | `SDKROOT = iphonesimulator` | `<configuration>-iphonesimulator/` | `Embed RuntimeViewerMobileServer Framework`, `Contents/Resources/` |

**This works only because each of those targets pins its own platform.** Swift
Build builds a dependency for the platform named by its own `SDKROOT` /
`SDK_VARIANT`; only `SDKROOT = auto` takes the app's. Leave these settings alone:
the usual Catalyst spelling, `SDKROOT = iphoneos` with
`SUPPORTS_MACCATALYST = YES`, turns into Catalyst only when the run destination
is Mac Catalyst, and under the app's macOS destination it builds an `iphoneos`
product instead. They live in the targets' xcconfig files,
`RuntimeViewerCatalystService/Shared.xcconfig`, `RuntimeViewerCatalystHelper/Shared.xcconfig` and
`RuntimeViewerSimulatorServer/Shared.xcconfig` — Xcode's build settings editor does not show
`SDK_VARIANT` at all — and every configuration of the three targets gets them from there, along with:

- `SKIP_INSTALL = YES`, so archiving the app does not also install the service,
  the helper or the payload as a product of its own — that would make the archive
  a generic one, which `-exportArchive` refuses. Exporting the app re-signs them
  for Developer ID along with everything else.
- On the helper, `RUNTIME_VIEWER_SERVICE_NAME`, per configuration (`com.mxiris…`
  for Release, `dev.mxiris…` for Debug, `dev.arm64e.mxiris…` for Debug-arm64e).
  It must match the app's: the helper reaches its host through the helper daemon
  of that name, and a helper on another daemon never finds the host's endpoint,
  so the Catalyst engine loads forever. The name is written once per
  configuration, in `ServiceName/<configuration>.xcconfig`, which
  the app, the helper and the daemon target (whose `PRODUCT_NAME` it is) all
  include, and building both in one configuration keeps them in step — **a new
  configuration needs a file of its own there, included by all three**.
  Background: `Documentations/ResolvedIssues/2026-09-09-catalyst-helper-wrong-daemon.md`.
  The service needs no such name: launchd finds it by bundle identifier inside
  the app, never through the daemon. A new configuration gives it a bundle
  identifier, in a `RuntimeViewerCatalystService/<configuration>.xcconfig`
  of its own, and sets `RUNTIME_VIEWER_CATALYST_SERVICE_BUNDLE_IDENTIFIER` in the
  app's xcconfig to match, the way the local-runtime service is done.

Xcode's build settings editor shows the payload target's Base SDK as
"iphonesimulator (SDK not found)". That is the editor only: its Base SDK pop-up
offers no simulator SDK, while the build resolves `iphonesimulator` normally.
Leave it — picking any SDK in that pop-up overwrites `SDKROOT`, and the payload
then builds for the wrong platform without an error.

`RuntimeViewerCatalystHelperPlugin`, the code both Catalyst shells load, is a
plain macOS bundle: it builds into `<configuration>/`, and the app's
`Embed Catalyst Plugin` phase copies it into `Contents/PlugIns/`. **The app ships
one copy, not one per shell** — the plugin is about 44 MB in Release, the
service and the helper are kilobytes — and `AppKitBridge` finds it two levels
up from either shell's own bundle (`Contents/XPCServices/…` and
`Contents/Applications/…` both sit below `Contents`). Its run path
`@loader_path/../../../../Frameworks` is the app's `Frameworks`, which is where
`libswiftCompatibilitySpan.dylib` comes from on a system whose `/usr/lib/swift`
lacks it; the app's copy covers macOS and Mac Catalyst alike, so the Catalyst
processes load it too. Moving the plugin, or a shell, changes those paths.

**The simulator payload has a target of its own.** `RuntimeViewerSimulatorServer`
compiles the same synchronized `RuntimeViewerServer/` folder and links the same
packages as `RuntimeViewerMobileServer`, which stays `SDKROOT = auto` because
`BuildRuntimeViewerServerXCFramework.sh` builds every other platform from it and
the jailbroken variant depends on it. Its `PRODUCT_NAME` is
`RuntimeViewerMobileServer`, the bundle name `PayloadPlatform` looks for;
`RuntimeInjectClient` reaches the binary through `Bundle.executableURL`, so the
binary's own name does not matter. The payload is copied, never linked — a macOS
app cannot link a simulator binary — and lands in `Contents/Resources/` because
`RuntimeInjectClient` finds it with `Bundle.main.url(forResource:withExtension:)`,
which looks nowhere else.

The old staging paths, `RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper.app` and
`RuntimeViewerUsingAppKit/RuntimeViewerMobileServer.framework`, are still gitignored for checkouts that
predate this; nothing reads or writes them. A build phase that built both from inside the app's build was
tried and withdrawn before this (evolution 0015). `Experiments/CatalystXPCServiceProbe` reproduces both
recipes in a minimal project, and showed that a Mac Catalyst XPC service embedded in a macOS app launches
and works, which is what `RuntimeViewerCatalystService` is built on; its README records what was measured.

## The jailbroken iOS variant

**It embeds the payload from `RuntimeViewerMobileServer` directly.** `RuntimeViewerUsingUIKit-JB` is
itself an iOS app, so the `SDKROOT = auto` target resolves to iOS for it: it carries a plain
`PBXTargetDependency` on `RuntimeViewerMobileServer` plus an `Embed RuntimeViewerMobileServer Framework`
copy phase. What is specific to it:

- The payload lands in `Frameworks/`, not `Contents/Resources/` — an iOS bundle
  is flat, so `url(forResource:withExtension:)` would not find it. The variant's
  `InjectionServiceRegistrar` goes through `Bundle.main.privateFrameworksURL`.
- `ARCHS[sdk=iphoneos*] = arm64 arm64e` on the payload target, because iOS
  system processes are arm64e while every third-party app is arm64; one slice
  reaches half the targets. The condition keeps the simulator and Catalyst
  slices as they were, and the `Distribution` configuration — the one
  `BuildRuntimeViewerServerXCFramework.sh` uses — is deliberately left alone, so
  the published XCFramework is unaffected. Debug also needs
  `ONLY_ACTIVE_ARCH[sdk=iphoneos*] = NO`, or a build onto a connected device
  silently drops the arm64 slice.
- **What gets injected is a staged directory, not a lone Mach-O.** The payload links
  `@rpath/libswiftCompatibilitySpan.dylib`, a back-deployment shim that iOS 26.5 ships in
  `/usr/lib/swift` and iOS 27 no longer does, so `RuntimePayloadStaging` copies the app's embedded
  libraries into a `Frameworks` directory beside the staged payload, which the payload's own
  `@loader_path/Frameworks` run-path entry resolves; its doc comments have the details. macOS 27 still
  ships the shim in `/usr/lib/swift`.
- **Signing and packaging are not Xcode's job here.** No provisioning profile
  grants the variant's five entitlements, so the target sets
  `CODE_SIGNING_ALLOWED = NO` and the product comes out unsigned;
  `BuildJailbrokenIPAScript.sh` pseudo-signs every Mach-O in it and packages the
  `.ipa`. A build installed by Xcode carries none of the five and can neither
  list processes nor inject into one. The signing is done by `vphone-cli sign`
  or by `ldid`, whichever is installed (`--signer` overrides): the first is a
  wrapper that writes byte for byte what `ldid -S -M -K -I` writes, so they are
  interchangeable here, and which one a machine has differs.

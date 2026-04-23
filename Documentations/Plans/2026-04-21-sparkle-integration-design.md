# Sparkle Auto-Update Integration Design

## Problem

RuntimeViewer currently has no auto-update mechanism. Users must discover new releases manually via the GitHub releases page and reinstall by hand. The project has two disjoint release paths:

- **Local**: `ArchiveScript.sh` produces a signed, notarized `RuntimeViewer-macOS.zip` but stops at "open Finder."
- **CI**: `.github/workflows/release.yml` (~280 lines) re-implements the same archive/notarize logic with a different credential model and also runs `gh release create`.

These paths duplicate logic and drift over time. Adding Sparkle on top of either without consolidation will triple the drift surface.

## Goals

1. Integrate Sparkle 2 for in-app automatic updates with EdDSA-signed feed, single appcast with channel-based beta opt-in.
2. Consolidate `ArchiveScript.sh` and the CI release workflow into a single `ReleaseScript.sh` used by both.
3. Keep `AppDelegate` effectively unchanged — updater logic lives in a dedicated `UpdaterService` class, following the existing `MCPService.shared` / `HelperServiceManager.shared` pattern.
4. Provide a usable Settings → Updates page matching the current SwiftUI settings architecture.
5. Document key generation, backup, and the rollout/rollback runbook.

## Non-Goals

- Redesigning the Sparkle UI. We use `SPUStandardUpdaterController`'s built-in dialogs; no custom `SPUUserDriver`.
- Updating the Catalyst helper (`RuntimeViewerCatalystHelper`) — it is an XPC bridge, not user-facing, and rides with the main app.
- Updating `RuntimeViewerUsingUIKit` (iOS) or `RuntimeViewerServer` (XPC service). Out of scope for this integration.
- Modifying `MainMenu.xib`. The "Check for Updates…" menu item is installed programmatically at runtime.

## Architecture Overview

```
┌────────────────────────── 开发机(发版者) ──────────────────────────┐
│  ./ReleaseScript.sh                                                 │
│    ├─ archive + notarize (login Keychain: "notarytool-password")    │
│    ├─ generate_appcast → docs/appcast.xml (EdDSA via login Keychain)│
│    └─ optionally --upload-to-github / --commit-push                 │
└─────────────────────────────────────────────────────────────────────┘
                        │ tag push or workflow_dispatch
                        ▼
┌────────────────────────── GitHub Actions ──────────────────────────┐
│  release.yml (~90 lines after reduction)                           │
│    prepare: certs import, Xcode select, sibling repos clone        │
│    ├─ decode SPARKLE_EDDSA_PRIVATE_KEY → $SPARKLE_ED_KEY_FILE      │
│    ├─ decode ASC API key → $NOTARY_KEY_FILE                        │
│    └─ ./ReleaseScript.sh --notary-api-key ... --ed-key-file ...    │
│                          --update-appcast --upload-to-github       │
│                          --commit-push --include-ios-simulator     │
└─────────────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌────── GitHub Releases + Pages (https://.../appcast.xml) ──────────┐
│  • Release asset:RuntimeViewer-macOS.zip (+ iOS Sim zip)          │
│  • docs/appcast.xml — single feed                                 │
│       stable entries: no <sparkle:channel> tag                    │
│       prerelease entries: <sparkle:channel>beta</sparkle:channel> │
└─────────────────────────────────────────────────────────────────────┘
                        │ HTTPS
                        ▼
┌─────────────────────── RuntimeViewer 用户机 ───────────────────────┐
│  AppDelegate (adds 2 lines)                                        │
│    applicationDidFinishLaunching  → UpdaterService.shared.start()  │
│    applicationWillTerminate       → UpdaterService.shared.stop()   │
│                                                                    │
│  UpdaterService (new, singleton, @MainActor)                       │
│    • holds SPUStandardUpdaterController                            │
│    • installs "Check for Updates…" menu item programmatically      │
│    • conforms to SPUUpdaterDelegate                                │
│    • binds Settings.update ↔ SPUUpdater properties                 │
│    • exposes read-only state to Settings UI                        │
│                                                                    │
│  Settings → Updates page (SwiftUI, new)                            │
└─────────────────────────────────────────────────────────────────────┘
```

## Detailed Design

### 1. In-App Integration

#### 1.1 `UpdaterService`

Location: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift`

```swift
import AppKit
import Sparkle
import RuntimeViewerSettings
import Dependencies
import OSLog

@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    @Dependency(\.settings) private var settings

    private var updaterController: SPUStandardUpdaterController?
    private var settingsObservation: Task<Void, Never>?

    private override init() { super.init() }

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        installCheckForUpdatesMenuItem(target: controller)
        applyInitialBindings(to: controller.updater)
        startSettingsObservation(for: controller.updater)
    }

    func stop() {
        settingsObservation?.cancel()
        settingsObservation = nil
        updaterController = nil
    }

    /// Invoked by Settings → Updates "Check Now" button.
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // Read-only state for Settings UI.
    var lastUpdateCheckDate: Date? { updaterController?.updater.lastUpdateCheckDate }
    var isSessionInProgress: Bool { updaterController?.updater.sessionInProgress ?? false }
    var currentVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Private

    private func installCheckForUpdatesMenuItem(target: SPUStandardUpdaterController) {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        let aboutIndex = appMenu.items.firstIndex {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        } ?? 0
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = target
        appMenu.insertItem(item, at: aboutIndex + 1)
    }

    private func applyInitialBindings(to updater: SPUUpdater) {
        let update = settings.update
        updater.automaticallyChecksForUpdates = update.automaticallyChecks
        updater.automaticallyDownloadsUpdates = update.automaticallyDownloads
        updater.updateCheckInterval = update.checkInterval.timeInterval
        updater.setAllowedChannels(update.allowedChannels)
    }

    private func startSettingsObservation(for updater: SPUUpdater) {
        // Uses withObservationTracking re-subscription loop to react to
        // changes on settings.update.* and re-apply to the updater.
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        settings.update.allowedChannels
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Log via @Loggable.
    }
}
```

**Key behaviors:**

- `start()` is idempotent — calling twice has no effect after the first.
- The menu item is inserted at runtime after the app menu is assembled; MainMenu.xib is not modified.
- `SPUUpdaterDelegate.allowedChannels(for:)` is the authoritative source for channel filtering, evaluated every check; it takes precedence over the initial `setAllowedChannels(_:)` call.

#### 1.2 `Settings.Update` model

Location: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Update.swift`

```swift
import Foundation
import MetaCodable

extension Settings {
    @Codable
    @MemberInit
    public struct Update {
        @Default(true)  public var automaticallyChecks: Bool
        @Default(false) public var automaticallyDownloads: Bool
        @Default(CheckInterval.daily) public var checkInterval: CheckInterval
        @Default(false) public var includePrereleases: Bool

        public static let `default` = Self()

        /// Maps to `SPUUpdater.setAllowedChannels(_:)` and
        /// `SPUUpdaterDelegate.allowedChannels(for:)`.
        ///
        /// Sparkle semantics: entries **without** a `<sparkle:channel>` tag are
        /// the "default channel" and are always visible. Returning an empty set
        /// means "default channel only." Returning `["beta"]` means "default +
        /// beta."
        public var allowedChannels: Set<String> {
            includePrereleases ? ["beta"] : []
        }
    }

    public enum CheckInterval: String, Codable, CaseIterable {
        case hourly, daily, weekly

        public var timeInterval: TimeInterval {
            switch self {
            case .hourly: 3_600
            case .daily:  86_400
            case .weekly: 604_800
            }
        }
    }
}
```

`Settings.swift` additions:

```swift
@Default(Update.default)
public var update: Update = .init() {
    didSet { scheduleAutoSave() }
}

// In `load()`:
update = decoded.update
```

#### 1.3 `UpdateSettingsView`

Location: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/UpdateSettingsView.swift`

Follows the existing `MCPSettingsView` layout conventions. Four sections:

1. **Status** — current version display, last check date (relative, "2 hours ago" / "Never"), "Check Now" button.
2. **Automatic Checks** — "Automatically check for updates" toggle; "Check every" picker (hourly/daily/weekly), disabled when the toggle is off.
3. **Installation** — "Automatically download and install" toggle (only effective if automatic checks is on).
4. **Channel** — "Include pre-release versions (Beta)" toggle with a descriptive subtitle.

The "Check Now" button calls `UpdaterService.shared.checkForUpdates()`; it is disabled while `UpdaterService.shared.isSessionInProgress` is true.

#### 1.4 `SettingsRootView` addition

```swift
private enum SettingsPage: String, CaseIterable, Identifiable {
    case general       = "General"
    case notifications = "Notifications"
    case transformer   = "Transformer"
    case mcp           = "MCP"
    case updates       = "Updates"   // new
    case helper        = "Helper"
    // ...

    var systemImage: String {
        switch self {
        // ...
        case .updates: "arrow.down.circle"
        // ...
        }
    }

    @ViewBuilder var contentView: some View {
        switch self {
        // ...
        case .updates: UpdateSettingsView()
        // ...
        }
    }
}
```

#### 1.5 `AppDelegate` changes

Add exactly two lines. The startup line joins the existing `applicationDidFinishLaunching` block next to `MCPService.shared.start(...)`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ...existing observe/appearance block...
    MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
    UpdaterService.shared.start()        // new
    installDebugMenu()
    checkHelperServiceVersion()
}

func applicationWillTerminate(_ notification: Notification) {
    UpdaterService.shared.stop()         // new
    MCPService.shared.stop()             // existing
}
```

No `import Sparkle` in `AppDelegate.swift`. All Sparkle types remain encapsulated in `UpdaterService.swift`.

#### 1.6 `Info.plist` additions

```xml
<key>SUFeedURL</key>
<string>$(SPARKLE_FEED_URL)</string>
<key>SUPublicEDKey</key>
<string>$(SPARKLE_PUBLIC_ED_KEY)</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUAllowsAutomaticUpdates</key>
<true/>
```

- `SUEnableAutomaticChecks = true` matches `Settings.Update.automaticallyChecks`'s default of `true`, so any momentary gap between Sparkle initialization and `UpdaterService.applyInitialBindings` does not flip behavior. `UpdaterService` remains the authoritative controller at steady state: every change in `Settings.update.automaticallyChecks` is written back to `SPUUpdater.automaticallyChecksForUpdates`.
- `SUAllowsAutomaticUpdates = true` permits the "download and install automatically" opt-in, exposed in Settings. `Settings.update.automaticallyDownloads` defaults to `false`, so nothing silent happens until the user explicitly enables it.

#### 1.7 `Debug.xcconfig` / `Release.xcconfig` additions

Both files receive:

```
SPARKLE_FEED_URL = https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml
SPARKLE_PUBLIC_ED_KEY = <base64 public key from generate_keys>
```

Debug and Release share the same feed URL and both run `UpdaterService.start()` — the code path is identical. Debug is isolated from production update noise at runtime: `UpdaterService` short-circuits its "initial automatic check on launch" logic when `Bundle.main.bundlePath` indicates a Debug bundle (the product name is `"RuntimeViewer-Debug"`, distinct from the Release name `"RuntimeViewer"`). The menu item is still installed so developers can test manually with "Check for Updates…", and the Settings page works normally.

The feed URL above assumes GitHub Pages project pages for `MxIris-Reverse-Engineering/RuntimeViewer`. If a custom domain is adopted later, only the xcconfig entries and the `--download-url-prefix` argument in `ReleaseScript.sh` need updating.

#### 1.8 SPM dependency

Add to `RuntimeViewerUsingAppKit.xcodeproj`:

- Package: `https://github.com/sparkle-project/Sparkle`
- Version rule: up-to-next-major from `2.6.0` (or the latest 2.x at integration time).
- Link `Sparkle` to target `RuntimeViewerUsingAppKit` only. Do **not** link to `RuntimeViewerCatalystHelper` or any iOS target.

### 2. Release Pipeline

#### 2.1 `ReleaseScript.sh`

A new script at the repository root. Parameter surface:

```
Usage: ./ReleaseScript.sh [options]

Build target:
  --workspace <path>                 default: RuntimeViewer-Distribution.xcworkspace
  --scheme <name>                    default: "RuntimeViewer macOS"
  --catalyst-helper-scheme <name>    default: RuntimeViewerCatalystHelper
  --configuration <Debug|Release>    default: Release
  --build-number <value>             default: $(date +"%Y%m%d.%H.%M")

Notarization (exactly one, or --skip-notarization):
  --notary-profile <keychain-profile>        # local default: "notarytool-password"
  --notary-api-key <path-to-.p8>
      --notary-key-id <id> --notary-issuer-id <id>

Distribution (all optional):
  --version-tag <vX.Y.Z[-suffix]>
  --channel <stable|beta>            # auto-inferred from tag if omitted
  --release-notes <path>             # typically Changelogs/<tag>.md
  --ed-key-file <path>               # EdDSA private key file
  --update-appcast                   # refresh docs/appcast.xml, preserving history
  --upload-to-github                 # gh release create / upload
  --commit-push                      # commit docs/appcast.xml and push to origin
  --include-ios-simulator            # build + zip iOS Simulator app

Misc:
  --skip-open-finder                 # CI sets this; local default: false
  --keep-intermediate                # preserve archives on success for debugging
  --dry-run                          # print all commands; do not execute mutations
```

Execution sequence:

1. Parse and validate arguments (mutually exclusive notarization modes; required flags for distribution steps).
2. Archive Catalyst helper → export → copy to `RuntimeViewerUsingAppKit/`.
3. Archive main app → export to `Products/Archives/Products/Export/`.
4. Notarize and staple (using `--notary-profile` or `--notary-api-key`).
5. If `--include-ios-simulator`: build iOS Simulator app → zip.
6. Package: `ditto -c -k --keepParent` main app → `RuntimeViewer-macOS.zip`.
7. If `--update-appcast`:
   - Copy/hardlink the zip into `.release-staging/`.
   - Run `generate_appcast .release-staging/ --appcast-file docs/appcast.xml -o docs/appcast.xml --download-url-prefix https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/download/<tag>/ --release-notes-url-prefix https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/tag/ [--ed-key-file <path>] [--channel beta]`.
   - `--channel beta` only when `CHANNEL=beta`; stable entries remain unmarked.
8. If `--upload-to-github`:
   - `gh release create <tag> --title "RuntimeViewer <tag>" --notes-file <notes> [--prerelease if CHANNEL=beta] RuntimeViewer-macOS.zip [RuntimeViewer-iOS-Simulator.zip]`
   - If the tag already exists (e.g., re-run after a fix), fall back to `gh release upload <tag> --clobber ...`.
9. If `--commit-push`: `git add docs/appcast.xml && git commit -m "chore: update appcast for <tag>" && git push origin HEAD`.
10. Unless `--skip-open-finder`, `open Products/Archives/Products/Export/`.
11. Print summary.

Channel inference when `--channel` is omitted:

```bash
case "$VERSION_TAG" in
    *-RC*|*-beta*|*-alpha*) CHANNEL="beta" ;;
    v[0-9]*)                 CHANNEL="stable" ;;
    *) fail "cannot infer channel from tag '$VERSION_TAG'; pass --channel explicitly" ;;
esac
```

#### 2.2 `ArchiveScript.sh` removal

`ArchiveScript.sh` is deleted from the repo as part of this change. Its prior behavior is reproduced by running `ReleaseScript.sh` with no distribution flags. The following are updated to point to the new script:

- `README.md`
- `CLAUDE.md` "Build Commands" section
- Any `Documentations/` content that references `ArchiveScript.sh`

#### 2.3 CI workflow slimming

`.github/workflows/release.yml` is restructured (target: ~90 lines):

- **Unchanged steps**: checkout, clone sibling repos, Xcode select, import signing certificates, keychain cleanup.
- **New steps**: decode `SPARKLE_EDDSA_PRIVATE_KEY` to a temp file; configure git author for push.
- **Replaced steps**: the entire "archive Catalyst helper → export → archive app → export → notarize → build iOS Simulator → package → (optionally) create release" block is replaced by a single `./ReleaseScript.sh ...` invocation.
- **New input**: `channel` (stable | beta) on `workflow_dispatch`; left unset on tag push and inferred by the script.

#### 2.4 GitHub Pages

- Repository Settings → Pages → Source = `main` branch, folder `/docs`.
- Feed URL: `https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml`.
- `docs/appcast.xml` becomes the single source of truth; `docs/index.html` is optional.

### 3. Key Management

#### 3.1 First-time key generation (one-off task in this branch)

```
1. Download Sparkle release tarball from
   https://github.com/sparkle-project/Sparkle/releases
2. Run bin/generate_keys once. It writes the ED25519 private key into the
   login Keychain (item "Private key for signing Sparkle updates",
   account "ed25519") and prints the base64 public key to stdout.
3. Put the public key into Debug.xcconfig and Release.xcconfig:
     SPARKLE_PUBLIC_ED_KEY = <base64 public key>
4. Export the private key for CI:
     bin/generate_keys -x sparkle_ed25519_priv.pem
     base64 < sparkle_ed25519_priv.pem | pbcopy
   Paste into GitHub repo secret SPARKLE_EDDSA_PRIVATE_KEY.
5. Encrypted cold backup (see 3.2). Then shred the plain-text export.
```

#### 3.2 Cold backup runbook

Documented in a new file `Documentations/SparkleRelease.md`:

- Login Keychain is the daily-use source; no direct file lives on disk.
- To produce a cold backup: export from Keychain (step 4 above), encrypt with GPG symmetric AES-256 (`gpg --symmetric --cipher-algo AES256 sparkle_ed25519_priv.pem`).
- Store the `.pem.gpg` file in at least two places: an offline encrypted drive and an encrypted password manager (e.g. 1Password Secure Note).
- Shred the unencrypted file after confirming backup integrity.
- CI secret `SPARKLE_EDDSA_PRIVATE_KEY` is a copy, not a replacement for the Keychain-or-backup pair; if Keychain is lost, the secret can be decoded back to restore Keychain.

#### 3.3 Emergency: total key loss

If both the Keychain copy and all cold backups are lost:

1. Generate a new EdDSA key pair.
2. Put the new public key into both xcconfig files and release normally.
3. Already-deployed users cannot auto-update to any release signed with the new key (old `SUPublicEDKey` rejects new signatures).
4. Pin a note to the top of `README.md` and the next GitHub Release instructing users to manually download the new release once.
5. After users install the new release, auto-update resumes.

### 4. Channel Semantics

**Sparkle 2 channel model recap**: appcast `<item>`s without a `<sparkle:channel>` tag belong to the "default channel" and are always visible. Items with a channel tag are hidden unless the updater has allowed that channel via `SPUUpdater.setAllowedChannels(_:)` or `SPUUpdaterDelegate.allowedChannels(for:)`.

Mapping:

| Release type | Tag example   | `<sparkle:channel>`        | `generate_appcast --channel` |
|--------------|---------------|----------------------------|------------------------------|
| Stable       | `v2.1.0`      | (no tag)                   | (not passed)                 |
| Prerelease   | `v2.1.0-RC.1` | `beta`                     | `beta`                       |

Settings wire-up:

- `Settings.update.includePrereleases = false` → `allowedChannels = []` → user sees only default-channel (stable) entries.
- `Settings.update.includePrereleases = true` → `allowedChannels = ["beta"]` → user sees default + beta.

CI inference matches the table (see 2.1).

## File Manifest

### New files

| Path | Purpose |
|------|---------|
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift` | Sparkle wrapper, delegate, Settings binding, menu install |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Update.swift` | `Settings.Update` model and `CheckInterval` enum |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/UpdateSettingsView.swift` | Settings → Updates SwiftUI view |
| `ReleaseScript.sh` | Unified build + notarize + distribute script |
| `Documentations/SparkleRelease.md` | Release runbook, key management, emergency recovery |

### Modified files

| Path | Change |
|------|--------|
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift` | 2-line additions: `UpdaterService.shared.start()` / `.stop()` |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Info.plist` | Sparkle keys |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Debug.xcconfig` | `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_ED_KEY` |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Release.xcconfig` | same |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj` | Sparkle SPM dependency + new file refs |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift` | `update: Update` field + `load()` sync |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift` | `.updates` case + icon + contentView |
| `.github/workflows/release.yml` | Slim down; invoke `ReleaseScript.sh`; new `channel` input; decode Sparkle secret |
| `README.md` | New "Updates" section; script reference change |
| `CLAUDE.md` | Build Commands section updated |

### Deleted files

| Path | Reason |
|------|--------|
| `ArchiveScript.sh` | Superseded by `ReleaseScript.sh` |

### New secrets and settings

| Location | Entry |
|----------|-------|
| GitHub repo Secrets | `SPARKLE_EDDSA_PRIVATE_KEY` (base64 ED25519 PEM) |
| GitHub repo Pages | Source = `main` / `/docs` |

## Testing & Verification

### End-to-end dry run (mandatory before merge)

```
1. Generate EdDSA key pair; fill xcconfig with the public key.
2. Locally: ./ReleaseScript.sh --version-tag v2.1.0-dryrun \
                 --channel beta --update-appcast
   Expected: RuntimeViewer-macOS.zip in Products/.../Export/;
             docs/appcast.xml gains one <item> with EdDSA signature and
             <sparkle:channel>beta</sparkle:channel>.
3. cd docs && python3 -m http.server 8080
4. Temporarily override SPARKLE_FEED_URL in Debug.xcconfig to
   http://127.0.0.1:8080/appcast.xml.
5. Run an older Debug build (lower MARKETING_VERSION / CURRENT_PROJECT_VERSION).
6. Menu "Check for Updates…" → Sparkle should fetch the feed, verify the
   EdDSA signature, prompt to install, install on quit, and the relaunched
   app should report the new version.
7. Validate notarization: xcrun stapler validate RuntimeViewer.app and
   spctl --assess --verbose RuntimeViewer.app.
8. git restore docs/appcast.xml and revert xcconfig changes.
```

### QA checklist

**In-app:**

- [ ] "Check for Updates…" appears directly below "About RuntimeViewer" in the app menu.
- [ ] `MainMenu.xib` has no diff on this branch.
- [ ] `AppDelegate.swift` does not `import Sparkle`.
- [ ] Settings → Updates page renders with all four sections.
- [ ] Toggling "Include pre-release versions" mid-session makes the next "Check Now" see/hide beta entries correctly (confirms `SPUUpdaterDelegate.allowedChannels(for:)` is consulted per check).
- [ ] Toggling "Automatically check for updates" persists across relaunch and `SPUUpdater.automaticallyChecksForUpdates` reflects it after `start()`.
- [ ] Corrupting one byte of an update zip causes Sparkle to reject the install with a signature error.
- [ ] Debug build does not spontaneously pop the Sparkle update prompt at launch.

**Release script:**

- [ ] `./ReleaseScript.sh` with no distribution flags produces the same artifacts the old `ArchiveScript.sh` did (zip + open Finder).
- [ ] `--version-tag v2.1.0-RC.1` alone yields `CHANNEL=beta` (inferred).
- [ ] `--version-tag v2.1.0` alone yields `CHANNEL=stable` (inferred).
- [ ] `--update-appcast` preserves pre-existing `<item>`s and inserts the new one sorted correctly by version.
- [ ] `--skip-notarization` plus `--configuration Debug` completes without touching notarytool.

**CI:**

- [ ] `workflow_dispatch` with `create_release=false` runs the build steps but does not create a GitHub Release or push to `docs/`.
- [ ] Tag push `v2.x.y` runs the full flow; `docs/appcast.xml` is pushed and reachable over HTTPS within Pages propagation time.
- [ ] iOS Simulator zip is still produced as a workflow artifact.
- [ ] Keychain cleanup runs under `if: always()`.

### Rollback

- **Bad release already tagged and in `appcast.xml`**: ship a higher-versioned hotfix; Sparkle never downgrades.
- **Rare emergency** (hotfix not yet available): `gh release edit <tag> --prerelease` to hide from default-channel clients, then remove the corresponding `<item>` from `docs/appcast.xml` and push. Already-upgraded users are unaffected; new installs simply do not see the update.
- **EdDSA private-key loss**: see § 3.3.

### Definition of Done

- [ ] End-to-end dry run performed and attached to PR description.
- [ ] `UpdaterService` unit test: `start()` idempotence, menu-item insertion, basic delegate wiring.
- [ ] `Settings.Update.allowedChannels` unit test: both directions.
- [ ] `Documentations/SparkleRelease.md` written and reviewed.
- [ ] `README.md` has an "Updates" section for end users.
- [ ] `CLAUDE.md` Build Commands section references `ReleaseScript.sh`.
- [ ] GitHub Pages source is set to `main` / `/docs`.
- [ ] `SPARKLE_EDDSA_PRIVATE_KEY` secret configured (author confirms).
- [ ] First post-merge trial: tag `v2.x.y-RC.N` from main; verify one beta-enabled tester receives and installs the update; then tag stable.

## Open Configuration Points

These values are finalized when the implementation starts (or during spec review):

- `SPARKLE_FEED_URL` — assumed `https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml`. If a custom domain is used, adjust xcconfig and `--download-url-prefix` default.
- Sparkle version pin — lock the lower bound to the latest stable `2.x` at integration time (tentatively `2.6.0`, adjust before merge); upper bound `..< 3.0.0` is fixed.
- Whether the Updates Settings page is placed before or after "Helper" in the sidebar — cosmetic, settle during implementation.

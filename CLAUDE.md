# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Keyloom is a macOS 26+ (arm64, Swift 6, warnings are errors) menu-bar text expander: snippets with `{argument}`, `{date}`, `{clipboard}`, `{cursor}` tokens, expanded when a keyword is typed in any app, with an optional iCloud sync and on-device writing assistance. Bundle id `com.thenaim.keyloom`. No SPM dependencies; the Xcode project uses folder-synced groups, so new files under `Keyloom/`, `KeyloomTests/`, `KeyloomUITests/` are picked up without editing the project.

## Commands

- Build Release into `.derived/`: `scripts/build.sh`
- Build, install to `/Applications` (checks bundle id, swaps with rollback) : `scripts/install.sh`. Quit the app first with `osascript -e 'tell application "/Applications/Keyloom.app" to quit'` (use the path: a bare `tell application "Keyloom"` can hit another running instance, e.g. a perf-profile build).
- Unit tests (all of `KeyloomTests`):
  `xcodebuild test -project Keyloom.xcodeproj -scheme Keyloom -destination 'platform=macOS' -derivedDataPath /tmp/keyloom-dd ENABLE_TESTABILITY=YES SWIFT_OPTIMIZATION_LEVEL=-Onone -only-testing:KeyloomTests`
  The two build settings are required: the Debug config otherwise yields a module `@testable import` rejects. One class or test: `-only-testing:KeyloomTests/KeystrokeInsertionTests` or `.../KeystrokeInsertionTests/testName`. Pipe through `grep -E "error:|failed|Executed|TEST (SUCCEEDED|FAILED)"`.
- UI tests: scheme `KeyloomUITests` (the app runs with `--keyloom-ui-test`, inert OS boundaries). `KeyloomProbe` and `Feasibility/` are a standalone feasibility probe, not part of the app.
  UI-test screenshots (the runner is sandboxed, tests attach them to the `.xcresult`): `scripts/export-ui-screenshots.sh <result.xcresult> [root]`.
- GitHub release: push tag `vX.Y.Z` (must equal `MARKETING_VERSION`) -> `.github/workflows/release.yml` (ad-hoc signed, not notarized, zip + sha256, bumps the cask from `packaging/homebrew/keyloom.rb` in `tankibaj/homebrew-tap`; needs secret `TAP_GITHUB_TOKEN`). `ci.yml` builds + unit-tests on main/PRs. `scripts/release/release.sh` stays the Developer ID path.
- Release (Developer ID, notarize) and idle profile: `scripts/release/release.sh --help`, `scripts/profile/profile.sh --help`.
- Logs (outcome names only, never text): `log show --last 5m --predicate 'subsystem == "com.thenaim.keyloom"'`.

## Architecture

Layers, bottom up: `Core` (pure: `Document`/`TokenParser`/`TemplateRenderer`, `KeywordMatcher`/`KeywordIndex`, search) -> `Store` (SQLite, one actor, tombstoned deletes, NFC keywords, usage is device-local) -> `Library/SnippetLibrary` (the single app-facing actor: after every write it reloads, rebuilds the keyword + search indexes and swaps them into `KeywordIndexStore`) -> `Host` (typing pipeline) and `UI` (SwiftUI, `AppEnvironment` is the composition root with `live` vs `uiTest` dependencies). `Sync` (CKSyncEngine, session-fenced, off by default), `Backups` (atomic snapshots), `Portability` (native + Raycast import/export) and `Assistance` (FoundationModels, explicit requests only) sit beside them.

**Typing pipeline (`Keyloom/Host`)**, spanning several files:
1. `EventTap` (active session tap, passes every event through) feeds `InputHost`, which applies privacy gates (paused, suspended, secure input, IME, excluded app, own/synthetic events) *before* building any key text, then `KeywordMatcher.feed`. The matcher reads the index directly, never the library actor, so typing never waits on the database. The callback must stay bounded: a match is handed off to a Task.
2. `InputHostController` is the UI-facing facade (status, pause, exclusions, shortcut, permission polling). `begin` suspends the host and runs `ExpansionCoordinator.handle`; keys typed meanwhile are dropped and counted as "activity" so the blind route can tell it was interrupted.
3. `TargetBinder` binds the keyword to the focused field through `AXDestination` (system-wide focus, then frontmost-app fallback), settling until two reads agree, and re-verifies before every write. Anything uncertain fails closed (`Refusal`), optionally with a Copy offer.
4. `InsertionEngine` writes via Accessibility (verified read-back). When Accessibility cannot see, read or write the field (browsers, Electron, terminals), `KeystrokeInserter` types over instead: Delete x keyword length + paste, posted to the frontmost pid, clipboard borrowed (tagged transient) and restored only while the change count is still ours. It is unverifiable, so it is guarded by interruption, secure input, exclusions, a role denylist and a Settings switch. Rich paste is an explicit user route only.
All OS boundaries (permissions, workspace, AX, pasteboard, key posting, tap, hotkeys) are protocols in `HostDependencies`; tests run the whole host against fakes in `KeyloomTests/Host/HostFakes.swift`.

## Gotchas

- Only Accessibility is requested (active tap, keystroke posting). Never reintroduce Input Monitoring / Post Events without a measured need.
- The build is ad-hoc signed, so TCC would drop the Accessibility grant on every rebuild; `install.sh` re-signs with a designated requirement on the bundle id to keep it. A bundle id change needs one fresh grant (`tccutil reset Accessibility <id>`).
- Preference keys and attributed-string keys keep the old `app.keyloom.` prefix on purpose (changing them resets saved settings); the bundle id is `com.thenaim.keyloom`. Snippet data lives in `~/Library/Application Support/Keyloom`, independent of the bundle id.
- iCloud sync needs a provisioned build (CloudKit entitlement, paid team); this build reports "not signed for iCloud".
- Typed text, snippet text and clipboard contents must never be logged, stored in errors or counters.
- Unit tests cover the typing route with fakes only; behavior in real apps (browsers, Electron, terminals) must be checked by hand against the installed build.
- Tests must not touch the real clipboard (use a named `NSPasteboard`) or install a real tap/hotkey (`AppEnvironment` picks inert dependencies under XCTest).

## UI conventions

- The UI follows the redesign mocks (menu-bar popover, Settings, library window, editor) and an Apple-Shortcuts-calm look: few toolbar controls over the column they act on (Sort over the list; New/Pin/Duplicate/Delete over the editor), status as a quiet dot + caption (never a toolbar chip), in-pane action bar for Edited/Revert/Save, small gray sidebar icons, symbol-and-color icon picker only (no emoji; old emoji icons fall back to a symbol). Tag colors are device-local (`app.keyloom.tagColors`) and do not sync.
- Library minimum is 1020x640, default 1180x760 (the toolbar must not fall into the » overflow); Settings is resizable (default ~720x560, min 640x480). Check changes by screenshot at min, ~1100x700 and full screen, light and dark (`LibraryWindowMetrics`).
- App icon: `Icon/AppIcon.icon` via `tools/make_icon.sh` / `tools/icon_review.sh`; `Icon/` is gitignored globally on some machines, so `git add -f` it if needed. After installing, a stale Dock icon needs `lsregister -f` + `killall Dock`.

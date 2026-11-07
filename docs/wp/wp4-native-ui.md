# Library, editor, picker and Settings
**Status:** In Progress | **Owner:** harnex | **Updated:** 2026-11-07 02:55

repo: /Users/naim/Repos/keyloom
depends: WP2 (slices A–C); WP3 reviewed host contracts (slices D–E)
parallel: yes (UI and services wave, own worktree)
Owned files: Keyloom/KeyloomApp.swift (existing, @main), Keyloom/{App,Views,Resources}/ (proposed), KeyloomTests/UIState/ (proposed), KeyloomUITests/Local/ (proposed), docs/BRIEF.md (proposed). Owns all scene and command bindings; sync/AI panels and models stay in their WP directories. Keyloom/AppIdentity.swift (existing) stays with WP1. The integration owner registers the new KeyloomUITests target and files in the project before slice A. Existing tests: KeyloomTests/AppIdentityTests (2) must stay green.

## Changes in order
- [ ] A (200–340): record mac-design archetype, IA, command map, empty states and feeling in docs/BRIEF.md before writing views. Three-column lazy library, All/Recently used/Pinned/tags, icon/name/keyword rows, search and row actions; standard menus, SF Symbols and the selected app mark.
- [ ] B1 (200–330): native AppKit rich-text control and bidirectional conversion of styles, paragraph runs and both list types to the WP2 model (UTF-16 offsets map directly); round-trip a styled token spanning Unicode.
- [ ] B2 (160–270): edit name/icon/tags/optional keyword, insert any supported placeholder, Save/Cancel, protect dirty edits on selection change, close and quit. UI tests exercise each dismissal.
- [ ] C (200–350): CRUD, duplicate/overlap feedback, pin, undo, editor preview/Try expansion and deletion recovery, committed through the WP2 store API. Reopen and verify stable ID and index refresh.
- [x] D (220–370): pinned-menu searchable popover, global picker keyboard search/preview/insert/copy and named-argument prompt with choices/defaults, on the real WP3 host lifecycle. Library, New, picker, pause and Settings available from the menu bar.
- [ ] E (160–340): Command-comma native Settings: General (Light/Dark/Auto, shortcuts), Expansion (pause, exclusions, permission status), Sync & Backups, Writing Assistance. Attach the real WP5–6 panels, command availability, system palette, focus and accessible labels.
  - D evidence: ArgumentPromptModel/CoordinatorTests, PickerSearch/ActionTests, MenuBarModelTests, AppEnvironmentTests (Release, all green). Not verified: live cross-app insert from picker/menu, panel visuals, Reduce Transparency.
  - E evidence: General/Expansion/Sync/Backups/Portability model tests green; Settings and library windows rendered in Release (dark). iCloud Sync binds `LocalOnlySyncSettings` (`TODO(keyloom-wp5-integrate)` in AppEnvironment.swift) until Keyloom/Sync merges, so E stays `[~]`. Editor Writing Tools/Apply-Cancel-Undo not listed for D/E: seam left (body stays `writingToolsBehavior = .none`).

## Done checks
- [ ] Native XCUITest (proposed `KeyloomUITests/Local`) drives empty library → create formatted follow-up → tag/filter/body search → trigger/confirm → edit/retest → delete/undo → relaunch. Picker arrows/Return/Escape, missing shortcuts, empty results, clipboard race, Cancel and dirty dismissal at each exit. Compare named surfaces to the prototype and mac-design in light, dark and Auto (screenshots to ignored paths); full Settings reviewed tab by tab.
- [ ] Save uses the native model of styled paragraphs/tokens; the HTML and its fake desktop/Draft are reference only. Ordinary typing and search make zero model calls.

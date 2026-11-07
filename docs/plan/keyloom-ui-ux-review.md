# Keyloom UI/UX review plan
**Status:** Draft | **Owner:** harnex | **Updated:** 2026-11-07 11:10

Scope: native macOS app (no browser). Runs once on the merged change, after the validator PASSes (never on a failing build). Reviewer: `harnex:ui-ux-reviewer`, never edits code.
Tooling: Claude computer use drives the Release `Keyloom.app` through real controls (mouse, keyboard); XCUITest journeys supply repeatable cases and light/dark/Auto snapshots. Computer use unavailable: each affected journey is NOT VERIFIED, never simulated.
Evidence: one screenshot per journey step (key state) in git-ignored `screenshots/<journey>/<NN>-<step>-<light|dark>.png`. The reviewer opens each one. A journey step without a screenshot is NOT VERIFIED.
Bar: Apple HIG / mac-design rules, WCAG 2.2 AA equivalents (contrast, focus, VoiceOver labels), keyboard-only operation. Findings need a concrete user cost or a cited rule; pure taste is NICE-TO-HAVE.

## Journeys (Snippet-App-Plan.md step 3)
- [ ] J1 Create: New snippet, name, icon (emoji and SF Symbol), keyword, tags, formatted body (bold, italic, underline, bullets, numbered), Insert Placeholder, Save; Cancel and dirty-edit protection (select away, close, quit).
- [ ] J2 Search: names, keywords, tags, body text; tag filter; All / Recently used / Pinned; empty library and no-result states recoverable by keyboard.
- [ ] J3 Insert: global picker (Control-Option-Space) and menu bar popover; type, navigate, preview, insert, copy; destination remembered; shortcut conflict surfaced.
- [ ] J4 Template arguments: recipient prompt opens immediately on keyword; repeated name reuses one answer; defaults; choices; Confirm places caret at cursor marker; Cancel leaves keyword intact; all values available expands directly.
- [ ] J5 Style preservation: substituted values inherit surrounding styles; styled and plain output agree.
- [ ] J6 Keywords: duplicate active keyword conflict shown; overlap warning (first completed keyword wins); case-sensitive match.
- [ ] J7 Clipboard during insertion: clipboard changed mid-insert is not overwritten; Copy fallback offered when replacement is unsafe.
- [ ] J8 Edit and retest: edit snippet, preview / Try expansion, stable ID kept on rename, index refreshes.
- [ ] J9 Delete and recover: delete, Undo, recover from deletion; duplicate snippet.
- [ ] J10 Settings (Command-comma): General (Light/Dark/Auto, shortcut), Expansion (pause, exclusions, permission status), Sync & Backups (iCloud off by default, status states, import/export, restore), Writing Assistance (off by default, unavailable and policy-forced states).
- [ ] J11 Accessibility: Reduce Transparency, Reduce Motion, Increase Contrast, VoiceOver labels, full keyboard walk, light/dark/Auto on every window.
- [ ] J12 Window resize (added by Naim): library window dragged from its minimum to a very large size and back, plus full screen and Split View width. Check the three-column split collapses sensibly (sidebar, list, editor), no clipped or overlapping controls, toolbar and search field stay usable, editor and preview scale, selection and unsaved draft survive a resize, empty and long-content states, minimum size is enforced. Also resize Settings, the picker panel and the argument prompt where resizable. Light and dark, a screenshot at minimum, default and large size per window.

Appearance (decided by Naim): one appearance only, the system's current one, not both light and dark. Earlier "light and dark" lines are narrowed to this; the other mode is NOT VERIFIED.

## Out of reach (NOT VERIFIED, by design)
Real typing into other apps (needs Accessibility and Input Monitoring grants), live CloudKit, macOS 26 hardware, managed Mac, VS Code (not installed). Waived by Naim for the WP1 gate.

## Deviations
Filled after the review: any journey skipped, changed or unverifiable versus this plan, with the reason.

_None yet._

# Native input and safe insertion
**Status:** In Progress | **Owner:** harnex | **Updated:** 2026-11-07 02:20

repo: /Users/naim/Repos/keyloom
depends: WP2 (integrated)
parallel: yes (first wave, own worktree, alongside WP5 A/B)
early-review: yes
Owned files (all proposed): Keyloom/Host/, KeyloomTests/Host/. Consumes WP2 store/matcher APIs and the reviewed WP1 probe findings; adapts, never links, Feasibility/Probe code. Exposes host actions and a request/cancel/confirm protocol to WP4. Existing tests: none for the shipping host; the probe's 44 stay in KeyloomProbe.

## Changes in order
- [x] A (220–380): shipping input host: Accessibility/Input Monitoring checked at point of use, secure input checked before any event text is read or buffered, pause and excluded bundle IDs, source tagging, invalidation on focus/composition/caret navigation. Bounded callback; DB, model and cloud off it.
- [x] B (200–350): destination identity and field/range/contents verification on trigger, after the prompt and immediately before replacement; AX writes bound to the captured element and revalidated before every mutation. Keyloom's own focus transfer handled distinctly from user changes. A changed or uninspectable target offers explicit Copy and preserves the typed keyword.
- [x] C (210–370): styles and plain text, pasteboard change count and restoration for supported types, rich/plain insertion, UTF-16 caret. Recheck adjacent content and cancellation. Restore only while the change count is still ours at the last instant; on ownership loss never restore, report it.
- [x] D (150–300): configurable system shortcut (default Control–Option–Space), conflicts, menu access; capture the original destination before showing UI. The prompt never consumes target text until confirmed.

## Done checks
- [ ] Host XCTest (proposed classes, e.g. HostSecureInputTests, TargetBindingTests, ClipboardOwnershipTests) via `xcodebuild … -scheme Keyloom -configuration Release … test -only-testing:KeyloomTests/<Class>`: invalidated focus/range, field changed after prompt, canceled argument, lost clipboard ownership, mixed scripts, secure input (text never read), permission revocation. Independent red on the Swift-only base. Repeat the WP1 destination walk on the shipping app after WP4 connects the controls: type without a delimiter, sentinel text around the trigger survives.
- [ ] No text deletion, paste or synthetic navigation to an uncertain target. Posted test events alone cannot prove a physical keyboard flow.

Implementer note: slices A-D built test-first in Keyloom/Host and KeyloomTests/Host (79 hosted tests green: InputHostTests, HostSecureInputTests, TargetBindingTests, InsertionTests, ClipboardOwnershipTests, ShortcutTests, ExpansionFlowTests, InputHostControllerTests). Done checks stay open: independent red by the validator, and the live destination walk after WP4 (NOT VERIFIED here).

# Optional native writing assistance
**Status:** In Progress | **Owner:** harnex | **Updated:** 2026-11-07 02:15

repo: /Users/naim/Repos/keyloom
depends: WP4 integrated editor selection/revision, protected-token, apply/undo and Settings attachment interfaces
parallel: yes (UI and services wave, own worktree; data code stays with WP5)
Owned files (all proposed): Keyloom/Assistance/, KeyloomTests/Assistance/, KeyloomUITests/Assistance/. Connects to the WP4 editor and Settings through their owner. Existing tests: none for this area.

## Changes in order
- [x] A (180–320): separate local opt-ins for assistance and system Writing Tools, both default off. Forced AllowWritingAssistance=false overrides both. Disable native writing tools in fields when off; check system capability/availability separately, use only the exposed reason, no policy bypass, Settings discloses Apple/external handling.
- [~] B (200–360): pure logic done (ProposedEdit pipeline, AssistanceService); real model adapter compile-only, editor attach pending WP4: on explicit request create an on-device session for selected prose only (proofread, shorten, tone). Token spans immutable, no placeholders resolved for the prompt; protect formatting outside the selection, reject altered token/order or stale selection/revision. Preview Apply/Cancel/Undo.
- [x] C (180–310): cancellation, stale-response fencing and session release on off, policy change or close. No automatic retries, setup prompts or invocation on search/typing. Clipboard, arguments and raw input stay out of logs and models.

## Done checks
- [ ] Count generation-boundary calls during the core journey (zero with both off and enabled-but-unused); selected-text-only request with synthetic data. Ready/downloading/unavailable/unsupported-language, token mutation, undo, delayed completion after disabling, system Writing Tools restriction. Proposed classes run via `xcodebuild … -scheme Keyloom -configuration Release … test -only-testing:KeyloomTests/<Class>`. Run a managed Mac with native Writing Tools restricted, the forced app switch, and separately restricted iCloud; verify local usability. Mocks do not certify MDM.
- [ ] If the OS only reports unavailable, display that reason. On a restricted device never suggest an equivalent rewriting route. Actual managed-Mac validation stays pending until exercised.

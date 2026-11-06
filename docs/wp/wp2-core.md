# Swift core and local store
**Status:** Blocked | **Owner:** harnex | **Updated:** 2026-11-06 23:24
Blocked until Naim approves feasibility: complete WP1 GO, or his explicit waiver naming the missing proof (live CloudKit proof is deferred; deferral alone is not approval).

repo: /Users/naim/Repos/keyloom
depends: WP1 GO
parallel: no
early-review: yes
Owned files (all proposed): Keyloom/Core/{Model,Matcher,Render,Search}/, Keyloom/Store/, KeyloomTests/Core/, KeyloomTests/Store/. Owns shared model/store APIs. Project registration of new files goes through the integration owner (WP1).
Stack: pure Swift 6, no third-party package. SQLite via the SDK's `import SQLite3`. Foundation Codable JSON. Spans are UTF-16 offsets validated on scalar boundaries, converted only at the AppKit/AX boundary. Matcher index is an immutable Sendable value swapped off the keyboard callback. Existing tests: none for this area; all below are proposed.

## Changes in order
- [ ] A (180–320): versioned Codable model for UUID, revision, icon, enabled keyword, tags, pin, paragraphs/lists, styled runs and literal/token spans; typed errors; UTF-16 offset helpers. Stub seams listed per slice for independent red.
- [ ] B1 (160–280): parse named/default/choice args, supported Raycast date/time/UUID/clipboard/cursor tokens, unknown literals and repeated names. Table-test exact source spans and malformed/unsupported input.
- [ ] B2 (170–300): render from the parsed model with injected date/time zone/locale, UUID and clipboard inputs. Assert styled and plain text agree, substitution inherits style and the UTF-16 caret is correct.
- [ ] C (200–340): bounded immediate case-sensitive matcher, first completed wins, duplicate/overlap feedback, invalidation, Unicode, immutable index swaps. Search all four fields, tags and empty cases.
- [ ] D1 (190–320): versioned SQLite schema: stable-ID CRUD, duplicate, delete/undo, pins, recent usage, revisions, keyword uniqueness and tombstones. Reopen and query by stable ID.
- [ ] D2 (160–290): transactionally journal local mutations and pending sync intent, account namespace and retry identity. Fault rollback, fixture migration, backup-before-migrate, restore on failure, downgrade guidance.
- [ ] E (160–300): app-facing store/index API (async, actor-isolated) that WP3–5 consume; persisted edits round-trip across relaunch through it from a real test client in the app target.

## Done checks
- [ ] `xcodebuild … -scheme Keyloom -configuration Release … test -only-testing:KeyloomTests/<Class>` for each slice (proposed classes per slice, e.g. TokenParserTests, RendererTests, MatcherTests, StoreTests, MigrationTests), then the full scheme. Reject malformed/oversized documents, a cursor inside a scalar or multiple markers. Combining marks, surrogate pairs and ZWJ, same-name reuse, formatting inheritance. Fault rollback and reopen SQLite: no partial row, no orphan outbox. Enabled-keyword uniqueness under conflicting concurrent writes; rename keeps the UUID.
- [ ] Recognition state is bounded; observed typing, prompts, rendered clipboard values and argument text are never persisted or logged. Formatting/insertion, including after relaunch, use the same committed representation.

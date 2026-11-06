# Portability, recovery and private sync
**Status:** Ready | **Owner:** harnex | **Updated:** 2026-11-06 23:24

repo: /Users/naim/Repos/keyloom
depends: WP2 (slices A–B); WP4 Settings attachment (slices C–E)
parallel: yes (A–B first wave, C–E UI and services wave, own worktree)
early-review: yes
Owned files (all proposed): Keyloom/{Portability,Backups,Reconcile,Sync}/, KeyloomTests/Data/, KeyloomUITests/Data/. WP2 owns the store/journal/outbox APIs this builds on; WP4 owns scene integration and the Settings attachment point. Needs the CloudKit entitlement/profile, whose live proof WP1-D2 deferred: C–E real-account evidence stays pending until it is proven or waived. Existing tests: none for this area.
Stack: pure Swift; native store from WP2 over system SQLite; Foundation Codable JSON; CKSyncEngine behind a protocol so a fake service injects quota/retry faults.

## Changes in order
- [ ] A (210–350): versioned all-fields native JSON and Raycast name/text/keyword interchange. Preview identical duplicates, disabled conflicts, literal unknown tokens and formatting loss. Accept the entire selected set in one transaction.
- [ ] B (220–360): atomic local snapshots on changed days, 30 daily and 10 most recent pre-import/pre-restore copies, pre-migration safeguard; restore queues sync changes. Retention boundaries, interrupted writes, unreadable/corrupt snapshot.
- [ ] C (220–360): persisted local-only sync switch (default off), Settings → Sync & Backups status/actions. Start/stop CKSyncEngine only when enabled; fence and drain in-flight callbacks, isolate per-account outbox and state tokens. Local edits/backups/expansion stay usable when off or unavailable.
- [ ] D1 (200–330): private record transport, durable per-account engine state, retry-safe acknowledgements; inject a crash after local commit and before remote ack, replay without duplication. Tombstone propagation offline and online.
- [ ] D2 (190–320): concurrent version/ancestor reconciliation including edit/edit and delete/edit; preserve both, disable active-keyword conflicts, ignore stale callbacks, never upload A's records to B or wipe data on switch-off.
- [ ] E (180–340): real two-Mac reconciliation and Settings interactions: unavailable, signed-out, quota, account switch with pending work, stale callbacks. Preserve local work under separately managed iCloud restriction.

## Done checks
- [ ] Swift XCTest (proposed classes e.g. ImportTests, SnapshotRetentionTests, ReconcileTests) via `xcodebuild … -scheme Keyloom -configuration Release … test -only-testing:KeyloomTests/<Class>`: whole-transaction rollback after malformed imports, invalid migrations and restore faults; styled fields round-trip byte-semantically; native→Raycast loss preview. Fake service only for deterministic quota/retry injection, reported apart from real quota observations. Independent red on the Swift-only base.
- [ ] Real signed test account (pending): sync both Macs, disable one, edit both offline/online, relaunch while off, re-enable, expect both versions; propagate a delete; switch accounts and prove no cross-account writes. Check an actual restricted-iCloud Mac.
- [ ] Local changes and pending intent commit atomically. Sync-off retains cloud records and local state. Never erase user cloud records for testing; use disposable fixture records in a test account.

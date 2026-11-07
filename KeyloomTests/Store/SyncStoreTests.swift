import XCTest
@testable import Keyloom

/// The store side of private sync: per-account engine state and ancestors, atomic remote application and the
/// push journal. Everything runs against a real SQLite file; nothing is mocked.
final class SyncStoreTests: StoreTestCase {
    private let accountA = "icloud:A"
    private let accountB = "icloud:B"

    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    private func remote(_ snippet: Snippet, fields: Data? = nil) -> RemoteChange { .upsert(snippet, systemFields: fields) }

    private func copyID(_ result: RemoteApplyResult, file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        guard case .conflictCopied(let id) = result.outcome else {
            XCTFail("expected a conflict copy, got \(result.outcome)", file: file, line: line)
            throw StoreError.closed
        }
        return id
    }

    // MARK: Schema v2

    func testSchemaV2AddsSyncTablesToAnExistingLibraryAfterABackup() async throws {
        let url = try databaseURL()
        let backups = url.deletingLastPathComponent().appendingPathComponent("backups")
        let first = try openStore(at: url, migrations: [Migrations.v1], backupDirectory: backups)
        let kept = try await first.create(makeSnippet(name: "Kept"))
        await first.close()

        let store = try openStore(at: url, backupDirectory: backups)
        let raw = try RawDatabase(url)
        XCTAssertEqual(try raw.userVersion, Migrations.all.count)
        XCTAssertEqual(try raw.count("sync_conflict_disabled"), 0)
        XCTAssertEqual(try raw.count("sync_records"), 0)
        XCTAssertEqual(try raw.count("sync_engine_state"), 0)
        let fetched = try await store.snippet(id: kept.id)
        XCTAssertEqual(fetched, kept)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertTrue(backupNames.contains { $0.hasPrefix("keyloom-pre-migration-v1-") }, "migration is preceded by a backup")
    }

    // MARK: Engine state and ancestors are per account

    func testEngineStateIsKeptPerAccountAndResetOnlyForOne() async throws {
        let store = try openStore(at: try databaseURL())
        let missing = try await store.syncEngineState(account: accountA)
        XCTAssertNil(missing)
        try await store.saveSyncEngineState(Data("a1".utf8), account: accountA)
        try await store.saveSyncEngineState(Data("b1".utf8), account: accountB)
        try await store.saveSyncEngineState(Data("a2".utf8), account: accountA)
        let stateA = try await store.syncEngineState(account: accountA)
        let stateB = try await store.syncEngineState(account: accountB)
        XCTAssertEqual(stateA, Data("a2".utf8))
        XCTAssertEqual(stateB, Data("b1".utf8))

        let snippet = makeSnippet()
        _ = try await store.applyRemote(remote(snippet), account: accountA)
        _ = try await store.applyRemote(remote(snippet), account: accountB)
        try await store.resetSyncMetadata(account: accountA)
        let resetState = try await store.syncEngineState(account: accountA)
        let baseA = try await store.syncBase(account: accountA, id: snippet.id)
        let keptState = try await store.syncEngineState(account: accountB)
        let baseB = try await store.syncBase(account: accountB, id: snippet.id)
        XCTAssertNil(resetState)
        XCTAssertNil(baseA)
        XCTAssertEqual(keptState, Data("b1".utf8))
        XCTAssertNotNil(baseB)
        let stillThere = try await store.snippet(id: snippet.id)
        XCTAssertNotNil(stillThere, "resetting sync metadata never touches the library")
    }

    func testInvalidAccountIsRejectedEverywhere() async throws {
        let store = try openStore(at: try databaseURL())
        await assertThrows(.invalidAccount) { _ = try await store.syncEngineState(account: " ") }
        await assertThrows(.invalidAccount) { _ = try await store.applyRemote(.delete(UUID()), account: "") }
        await assertThrows(.invalidAccount) { _ = try await store.prepareSync(account: "") }
    }

    // MARK: Applying remote changes

    func testNewRemoteRecordIsCreatedWithoutJournalingItBack() async throws {
        let store = try openStore(at: try databaseURL())
        let incoming = makeSnippet(name: "From cloud", keyword: ";cloud")
        let result = try await store.applyRemote(remote(incoming, fields: Data("tag1".utf8)), account: accountA)
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.libraryChanged)
        let stored = try await store.snippet(id: incoming.id)
        XCTAssertEqual(stored?.name, "From cloud")
        XCTAssertEqual(stored?.keyword, ";cloud")
        let pending = try await store.pending(account: accountA)
        let pendingLocal = try await store.pending()
        XCTAssertEqual(pending, [], "applying a remote change is not a local mutation")
        XCTAssertEqual(pendingLocal, [])
        let base = try await store.syncBase(account: accountA, id: incoming.id)
        XCTAssertEqual(base?.systemFields, Data("tag1".utf8))
        XCTAssertEqual(base?.snapshot?.name, "From cloud")
    }

    func testRedeliveredRecordChangesNothing() async throws {
        let store = try openStore(at: try databaseURL())
        let incoming = makeSnippet()
        _ = try await store.applyRemote(remote(incoming), account: accountA)
        let before = try await store.snippet(id: incoming.id)
        let again = try await store.applyRemote(remote(incoming, fields: Data("tag2".utf8)), account: accountA)
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertFalse(again.libraryChanged)
        let after = try await store.snippet(id: incoming.id)
        XCTAssertEqual(before, after, "a replay never bumps the revision")
        let base = try await store.syncBase(account: accountA, id: incoming.id)
        XCTAssertEqual(base?.systemFields, Data("tag2".utf8), "but the newer server tag is kept")
    }

    func testRemoteEditFastForwardsAnUntouchedLocalCopy() async throws {
        let store = try openStore(at: try databaseURL())
        let original = makeSnippet(name: "v1")
        _ = try await store.applyRemote(remote(original), account: accountA)
        var edited = original
        edited.name = "v2"
        edited.revision = 2
        let result = try await store.applyRemote(remote(edited), account: accountA)
        XCTAssertEqual(result.outcome, .applied)
        let stored = try await store.snippet(id: original.id)
        XCTAssertEqual(stored?.name, "v2")
        let all = try await store.allSnippets()
        XCTAssertEqual(all.count, 1)
    }

    func testEditEditKeepsRemoteAndPreservesLocalAsANamedConflictCopy() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let original = makeSnippet(name: "Base", keyword: ";kw", text: "base")
        _ = try await store.applyRemote(remote(original), account: accountA)
        var local = original
        local.name = "Mine"
        _ = try await store.update(local)

        var theirs = original
        theirs.name = "Theirs"
        theirs.revision = 2
        let result = try await store.applyRemote(remote(theirs), account: accountA)
        let copy = try copyID(result)

        let winner = try await store.snippet(id: original.id)
        XCTAssertEqual(winner?.name, "Theirs")
        let preservedCopy = try await store.snippet(id: copy)
        let preserved = try XCTUnwrap(preservedCopy)
        XCTAssertTrue(preserved.name.hasPrefix("Mine (conflict copy "), preserved.name)
        XCTAssertFalse(preserved.enabled, "the copy shares the keyword with the original, so it starts disabled")
        XCTAssertEqual(preserved.keyword, ";kw")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending.map(\.recordID), [copy], "only the copy is queued; the superseded local edit is dropped")
        let base = try await store.syncBase(account: accountA, id: original.id)
        XCTAssertEqual(base?.snapshot?.name, "Theirs")
    }

    func testConflictCopyWithAFreeKeywordStaysEnabled() async throws {
        let store = try openStore(at: try databaseURL())
        let original = makeSnippet(name: "Base", keyword: ";old")
        _ = try await store.applyRemote(remote(original), account: accountA)
        var local = original
        local.keyword = ";mine"
        _ = try await store.update(local)
        var theirs = original
        theirs.name = "Theirs"
        let copy = try copyID(try await store.applyRemote(remote(theirs), account: accountA))
        let preserved = try await store.snippet(id: copy)
        XCTAssertEqual(preserved?.keyword, ";mine")
        XCTAssertEqual(preserved?.enabled, true)
    }

    func testIdenticalConcurrentEditsAreNotAConflict() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let original = makeSnippet(name: "Base")
        _ = try await store.applyRemote(remote(original), account: accountA)
        var local = original
        local.name = "Same"
        _ = try await store.update(local)
        var theirs = original
        theirs.name = "Same"
        let result = try await store.applyRemote(remote(theirs), account: accountA)
        XCTAssertEqual(result.outcome, .unchanged)
        let all = try await store.allSnippets()
        XCTAssertEqual(all.count, 1)
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending, [], "nothing left to push")
    }

    func testRemoteDeleteTrashesAnUntouchedLocalCopyAndKeepsItRecoverable() async throws {
        let store = try openStore(at: try databaseURL())
        let original = makeSnippet()
        _ = try await store.applyRemote(remote(original), account: accountA)
        let result = try await store.applyRemote(.delete(original.id), account: accountA)
        XCTAssertEqual(result.outcome, .deleted)
        let live = try await store.snippet(id: original.id)
        XCTAssertNil(live)
        let trash = try await store.deletedSnippets()
        XCTAssertEqual(trash.map(\.snippet.id), [original.id], "a remote delete lands in the trash, not in oblivion")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending, [], "a remote delete is not echoed back")
    }

    func testRemoteDeleteVersusLocalEditPreservesTheEditAsACopy() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let original = makeSnippet(name: "Base", keyword: ";kw")
        _ = try await store.applyRemote(remote(original), account: accountA)
        var local = original
        local.name = "Edited here"
        _ = try await store.update(local)
        let result = try await store.applyRemote(.delete(original.id), account: accountA)
        let copy = try copyID(result)
        let gone = try await store.snippet(id: original.id)
        XCTAssertNil(gone, "the delete is honored on the original")
        let preserved = try await store.snippet(id: copy)
        XCTAssertTrue(preserved?.name.hasPrefix("Edited here (conflict copy ") == true)
        XCTAssertEqual(preserved?.enabled, true, "the original no longer holds the keyword")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending.map(\.recordID), [copy], "the old edit is not re-uploaded over the delete")
    }

    func testLocalDeleteVersusRemoteEditPreservesTheEditAsACopyAndKeepsTheDeleteQueued() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let original = makeSnippet(name: "Base", keyword: ";kw")
        _ = try await store.applyRemote(remote(original), account: accountA)
        try await store.delete(id: original.id)
        var theirs = original
        theirs.name = "Edited elsewhere"
        let result = try await store.applyRemote(remote(theirs), account: accountA)
        let copy = try copyID(result)
        let preserved = try await store.snippet(id: copy)
        XCTAssertTrue(preserved?.name.hasPrefix("Edited elsewhere (conflict copy ") == true)
        let stillDeleted = try await store.snippet(id: original.id)
        XCTAssertNil(stillDeleted)
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(Set(pending.map(\.recordID)), [original.id, copy])
        XCTAssertTrue(pending.contains { $0.recordID == original.id && $0.operation == .delete })
    }

    func testYoungerRemoteRecordWithATakenKeywordArrivesDisabledAndLeavesTheLocalOwnerAlone() async throws {
        let store = try openStore(at: try databaseURL())
        let owner = try await store.create(makeSnippet(name: "Mine", keyword: ";same"))
        clock.advance(by: 10)
        let incoming = makeSnippet(name: "Theirs", keyword: ";same")
        let result = try await store.applyRemote(remote(incoming), account: accountA)
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.disabledForKeywordConflict)
        let arrived = try await store.snippet(id: incoming.id)
        XCTAssertEqual(arrived?.enabled, false)
        let kept = try await store.snippet(id: owner.id)
        XCTAssertEqual(kept?.enabled, true)
        let analysis = KeywordConflicts.analyze(try await store.allSnippets())
        XCTAssertEqual(analysis.conflicts, [], "no duplicate active keyword after sync")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending, [], "the forced disable is local; it is not pushed over the remote record")
        let notices = try await store.keywordConflictDisabledIDs()
        XCTAssertEqual(notices, [incoming.id], "the user can be told which snippet was turned off")
    }

    func testOlderRemoteRecordWinsTheKeywordAndTheLocalOwnerIsTurnedOffWithoutBeingPushed() async throws {
        let store = try openStore(at: try databaseURL())
        let older = makeSnippet(name: "Older, from the cloud", keyword: ";same")
        clock.advance(by: 10)
        try await store.setSyncAccount(accountA)
        let owner = try await store.create(makeSnippet(name: "Younger, local", keyword: ";same"))
        let result = try await store.applyRemote(remote(older), account: accountA)
        XCTAssertTrue(result.disabledForKeywordConflict)
        XCTAssertTrue(result.libraryChanged)
        let winner = try await store.snippet(id: older.id)
        XCTAssertEqual(winner?.enabled, true, "the same snippet wins on every Mac: earliest creation, then ID")
        let loser = try await store.snippet(id: owner.id)
        XCTAssertEqual(loser?.enabled, false)
        let notices = try await store.keywordConflictDisabledIDs()
        XCTAssertEqual(notices, [owner.id])

        // The loser was never uploaded; when it is, it carries the user's intent (enabled), not the forced state.
        let outgoing = try await store.nextOutgoing(account: accountA, limit: 10)
        guard case .save(let sent)? = outgoing.first?.payload else { return XCTFail("expected the loser to be sent") }
        XCTAssertEqual(sent.id, owner.id)
        XCTAssertTrue(sent.enabled, "a conflict-forced disable is not a user edit")
    }

    func testAForcedDisableIsNotQueuedAndAnEditToTheLoserKeepsItsIntent() async throws {
        let store = try openStore(at: try databaseURL())
        let older = makeSnippet(name: "Older", keyword: ";same")
        _ = try await store.applyRemote(remote(older), account: accountA)
        clock.advance(by: 10)
        let younger = makeSnippet(name: "Younger", keyword: ";same")
        _ = try await store.applyRemote(remote(younger, fields: Data("t".utf8)), account: accountA)
        let loser = try await store.snippet(id: younger.id)
        XCTAssertEqual(loser?.enabled, false)

        let prepared = try await store.prepareSync(account: accountA)
        XCTAssertEqual(prepared.enqueued, 0, "the forced disable differs from the ancestor but is not a change to push")

        try await store.setSyncAccount(accountA)
        var edited = try XCTUnwrap(loser)
        edited.tags = ["edited"]
        _ = try await store.update(edited)
        let outgoing = try await store.nextOutgoing(account: accountA, limit: 10)
        guard case .save(let sent)? = outgoing.first?.payload else { return XCTFail("expected a save") }
        XCTAssertEqual(sent.tags, ["edited"])
        XCTAssertTrue(sent.enabled, "the tag edit does not flip the record's enabled state in iCloud")
    }

    func testCanonicalKeywordFormIsComparedWhenResolvingConflicts() async throws {
        let store = try openStore(at: try databaseURL())
        _ = try await store.create(makeSnippet(name: "Mine", keyword: ";caf\u{00E9}"))
        clock.advance(by: 10)
        let incoming = makeSnippet(name: "Theirs", keyword: ";cafe\u{0301}")
        let result = try await store.applyRemote(remote(incoming), account: accountA)
        XCTAssertTrue(result.disabledForKeywordConflict)
    }

    func testInvalidRemoteRecordIsRejectedAndChangesNothing() async throws {
        let store = try openStore(at: try databaseURL())
        let existing = try await store.create(makeSnippet(name: "Safe"))
        var blank = makeSnippet(id: existing.id, name: "  ")
        blank.revision = 5
        do {
            _ = try await store.applyRemote(remote(blank), account: accountA)
            XCTFail("a blank name must be rejected at the trust boundary")
        } catch {
            XCTAssertEqual(error as? KeyloomError, .invalidSnippet(field: "name", reason: "must not be blank"))
        }
        let unchanged = try await store.snippet(id: existing.id)
        XCTAssertEqual(unchanged?.name, "Safe")
        let base = try await store.syncBase(account: accountA, id: existing.id)
        XCTAssertNil(base)
    }

    func testRemoteChangeNeverOverwritesAnUnreadableLocalRow() async throws {
        let url = try databaseURL()
        let store = try openStore(at: url)
        let snippet = try await store.create(makeSnippet())
        try RawDatabase(url).execute("UPDATE snippets SET template = x'7b7d' WHERE id = '\(snippet.id.uuidString)'")
        var theirs = snippet
        theirs.name = "Remote"
        await assertThrows(.corruptRecord(column: "template")) {
            _ = try await store.applyRemote(self.remote(theirs), account: self.accountA)
        }
        XCTAssertEqual(try RawDatabase(url).text("SELECT name FROM snippets"), "Greeting")
    }

    func testRemoteApplicationsAreIsolatedPerAccount() async throws {
        let store = try openStore(at: try databaseURL())
        let incoming = makeSnippet()
        _ = try await store.applyRemote(remote(incoming, fields: Data("a".utf8)), account: accountA)
        let baseB = try await store.syncBase(account: accountB, id: incoming.id)
        XCTAssertNil(baseB, "account B knows nothing about A's record")
    }

    // MARK: Preparing a start

    func testPrepareAdoptsLocalIntentsAndQueuesUnsyncedSnippetsOnce() async throws {
        let store = try openStore(at: try databaseURL())
        let one = try await store.create(makeSnippet(name: "One", keyword: ";1"))
        let two = try await store.create(makeSnippet(name: "Two", keyword: ";2"))
        try await store.delete(id: two.id)
        let result = try await store.prepareSync(account: accountA)
        XCTAssertEqual(result.adopted, 3, "all three local intents move to the account")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(Set(pending.map(\.recordID)), [one.id, two.id])
        let local = try await store.pending(account: "local")
        XCTAssertEqual(local, [])
        let again = try await store.prepareSync(account: accountA)
        XCTAssertEqual(again, SyncPreparation(adopted: 0, enqueued: 0), "preparing twice adds nothing")
    }

    func testPrepareFindsLocalEditsMadeWhileJournalingUnderAnotherAccount() async throws {
        let store = try openStore(at: try databaseURL())
        let original = makeSnippet(name: "Base")
        _ = try await store.applyRemote(remote(original), account: accountA)
        try await store.setSyncAccount(accountB)
        var edited = original
        edited.name = "Edited under B"
        _ = try await store.update(edited)
        try await store.setSyncAccount("local")

        let result = try await store.prepareSync(account: accountA)
        XCTAssertEqual(result.enqueued, 1, "the edit differs from A's ancestor, so it is queued for A")
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending.map(\.recordID), [original.id])
    }

    func testRecordsOwnedByAnotherAccountAreNeverQueuedForThisOne() async throws {
        let store = try openStore(at: try databaseURL())
        let ownedByA = makeSnippet(name: "A's", keyword: ";a")
        _ = try await store.applyRemote(remote(ownedByA), account: accountA)
        let neverSynced = try await store.create(makeSnippet(name: "Local only", keyword: ";l"))
        var edited = ownedByA
        edited.name = "A's, edited while off"
        _ = try await store.update(edited)

        let result = try await store.prepareSync(account: accountB)
        XCTAssertEqual(result.adopted, 1, "only the never-synced snippet's intent is adopted")
        let pending = try await store.pending(account: accountB)
        XCTAssertEqual(pending.map(\.recordID), [neverSynced.id])
        let outgoing = try await store.nextOutgoing(account: accountB, limit: 10)
        XCTAssertEqual(outgoing.map(\.recordID), [neverSynced.id], "A's snippet is not part of B's upload")
        let aStillQueued = try await store.pending(account: "local")
        XCTAssertEqual(aStillQueued.map(\.recordID), [ownedByA.id], "its intent stays in the local queue for A to adopt")
    }

    func testIntentsJournaledUnderAnAccountForAnotherAccountsRecordAreDroppedNotSent() async throws {
        let store = try openStore(at: try databaseURL())
        let ownedByA = makeSnippet(name: "A's", keyword: ";a")
        _ = try await store.applyRemote(remote(ownedByA), account: accountA)
        try await store.setSyncAccount(accountB)
        var edited = ownedByA
        edited.name = "Edited while B is active"
        _ = try await store.update(edited)

        let outgoing = try await store.nextOutgoing(account: accountB, limit: 10)
        XCTAssertEqual(outgoing, [], "A's snippet is never part of B's upload")
        let left = try await store.pending(account: accountB)
        XCTAssertEqual(left, [], "the intent is dropped; A finds the edit again by comparing state when it returns")
    }

    func testARecordStillQueuedForAnotherAccountIsNotUploadedToThisOne() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let unsent = try await store.create(makeSnippet(name: "Written while A was active", keyword: ";u"))
        try await store.setSyncAccount(SnippetStore.localSyncAccount)

        let result = try await store.prepareSync(account: accountB)
        XCTAssertEqual(result, SyncPreparation(adopted: 0, enqueued: 0), "A's queued intent is not B's to adopt or recreate")
        let outgoing = try await store.nextOutgoing(account: accountB, limit: 10)
        XCTAssertEqual(outgoing, [])
        let stillQueuedForA = try await store.pending(account: accountA)
        XCTAssertEqual(stillQueuedForA.map(\.recordID), [unsent.id])

        let back = try await store.prepareSync(account: accountA)
        XCTAssertEqual(back.enqueued, 0, "A's own queue already holds it")
        let forA = try await store.nextOutgoing(account: accountA, limit: 10)
        XCTAssertEqual(forA.map(\.recordID), [unsent.id], "it goes to A when A is back")
    }

    // MARK: Outgoing changes and acknowledgements

    func testOutgoingCoalescesIntentsAndCarriesTheNewestStateWithServerTag() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let created = try await store.create(makeSnippet(name: "v1"))
        var edited = created
        edited.name = "v2"
        _ = try await store.update(edited)
        let outgoing = try await store.nextOutgoing(account: accountA, limit: 10)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.retryIDs.count, 2)
        guard case .save(let snapshot)? = outgoing.first?.payload else { return XCTFail("expected a save") }
        XCTAssertEqual(snapshot.name, "v2")
        XCTAssertNil(outgoing.first?.systemFields)
    }

    func testOutgoingForADeletedSnippetIsADeleteWithItsKnownServerFields() async throws {
        let store = try openStore(at: try databaseURL())
        let incoming = makeSnippet()
        _ = try await store.applyRemote(remote(incoming, fields: Data("tag".utf8)), account: accountA)
        try await store.setSyncAccount(accountA)
        try await store.delete(id: incoming.id)
        let outgoing = try await store.nextOutgoing(account: accountA, limit: 10)
        XCTAssertEqual(outgoing.first?.payload, .delete)
        XCTAssertEqual(outgoing.first?.systemFields, Data("tag".utf8))
    }

    func testIntentsThatChangeNothingAreAcknowledgedWithoutSending() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let created = try await store.create(makeSnippet())
        try await store.delete(id: created.id)
        try await store.purge(id: created.id)
        let neverSynced = try await store.nextOutgoing(account: accountA, limit: 10)
        XCTAssertEqual(neverSynced, [], "created and deleted before any sync: nothing to tell the cloud")
        let left = try await store.pending(account: accountA)
        XCTAssertEqual(left, [])
    }

    func testRecordSentAcknowledgesAtomicallyAndIsSafeToRepeat() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let created = try await store.create(makeSnippet(name: "v1"))
        let change = try await store.nextOutgoing(account: accountA, limit: 10)[0]
        var edited = created
        edited.name = "v2-while-in-flight"
        _ = try await store.update(edited)

        try await store.recordSent(change, systemFields: Data("t1".utf8), account: accountA)
        try await store.recordSent(change, systemFields: Data("t1".utf8), account: accountA)

        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending.count, 1, "the edit made during the push is still queued")
        let base = try await store.syncBase(account: accountA, id: created.id)
        XCTAssertEqual(base?.snapshot?.name, "v1", "the ancestor is what was sent, not what is local now")
        XCTAssertEqual(base?.systemFields, Data("t1".utf8))
        let next = try await store.nextOutgoing(account: accountA, limit: 10)
        XCTAssertEqual(next.first?.systemFields, Data("t1".utf8))
    }

    func testRecordSentForADeleteRecordsADeletedAncestor() async throws {
        let store = try openStore(at: try databaseURL())
        let incoming = makeSnippet()
        _ = try await store.applyRemote(remote(incoming, fields: Data("t".utf8)), account: accountA)
        try await store.setSyncAccount(accountA)
        try await store.delete(id: incoming.id)
        let change = try await store.nextOutgoing(account: accountA, limit: 10)[0]
        try await store.recordSent(change, systemFields: nil, account: accountA)
        let base = try await store.syncBase(account: accountA, id: incoming.id)
        XCTAssertNotNil(base)
        XCTAssertNil(base?.snapshot)
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending, [])
    }

    func testRecordSentOnlyTouchesItsOwnAccount() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let created = try await store.create(makeSnippet())
        let change = try await store.nextOutgoing(account: accountA, limit: 10)[0]
        try await store.recordSent(change, systemFields: nil, account: accountB)
        let pendingA = try await store.pending(account: accountA)
        XCTAssertEqual(pendingA.count, 1, "B's acknowledgement cannot clear A's queue")
        let baseA = try await store.syncBase(account: accountA, id: created.id)
        XCTAssertNil(baseA)
    }

    func testMarkFailedKeepsRetryIdentityForEveryIntent() async throws {
        let store = try openStore(at: try databaseURL())
        try await store.setSyncAccount(accountA)
        let created = try await store.create(makeSnippet())
        var edited = created
        edited.name = "v2"
        _ = try await store.update(edited)
        let change = try await store.nextOutgoing(account: accountA, limit: 10)[0]
        try await store.markFailed(retryIDs: change.retryIDs, account: accountA)
        let pending = try await store.pending(account: accountA)
        XCTAssertEqual(pending.map(\.attempts), [1, 1])
        XCTAssertEqual(Set(pending.map(\.retryID)), Set(change.retryIDs))
        let count = try await store.pendingCount(account: accountA)
        XCTAssertEqual(count, 2)
    }
}

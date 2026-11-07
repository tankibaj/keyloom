import XCTest
@testable import Keyloom

final class SnippetLibraryTests: StoreTestCase {
    private func databaseURL() throws -> URL { try makeDirectory().appendingPathComponent("keyloom.sqlite") }

    private func openLibrary(at url: URL) async throws -> SnippetLibrary {
        try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                 now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
    }

    private func document(_ source: String) throws -> Document { try TokenParser.parse(source).document }

    private func environment() -> RenderEnvironment {
        RenderEnvironment(date: Date(timeIntervalSince1970: 1_768_485_909), timeZone: TimeZone(identifier: "UTC")!,
                          locale: Locale(identifier: "en_US_POSIX"), makeUUID: { UUID() }, clipboardText: { nil })
    }

    private func match(_ library: SnippetLibrary, _ typed: String) async -> UUID? {
        let matcher = library.keywordMatcher
        matcher.invalidate()
        return matcher.feed(typed)?.snippetID
    }

    private func assertThrowsTyped<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line,
                                                         _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }

    // MARK: Relaunch

    func testPersistedEditsRoundTripAcrossRelaunch() async throws {
        let url = try databaseURL()
        let library = try await openLibrary(at: url)
        let template = try document("Dear {argument name=\"who\" default=\"team\"}, {cursor}")
        let created = try await library.create(name: "Greeting", icon: .emoji("👋"), keyword: ";hi", enabled: true,
                                               tags: ["work", "mail"], template: template)
        var edited = created
        edited.icon = .symbol("star")
        edited.keyword = ";hey"
        edited.tags = ["mail", "work", "new"]
        edited.template = try document("Hey {date}")
        _ = try await library.update(edited)
        _ = try await library.rename(id: created.id, to: "Hello")
        _ = try await library.setPinned(true, id: created.id)
        await library.close()

        let reopened = try await openLibrary(at: url)
        let loaded = await reopened.snippet(id: created.id)
        XCTAssertEqual(loaded?.id, created.id)
        XCTAssertEqual(loaded?.name, "Hello")
        XCTAssertEqual(loaded?.icon, .symbol("star"))
        XCTAssertEqual(loaded?.keyword, ";hey")
        XCTAssertEqual(loaded?.tags, ["mail", "work", "new"])
        XCTAssertEqual(loaded?.template, edited.template)
        XCTAssertEqual(loaded?.pinned, true)
        let all = await reopened.allSnippets()
        XCTAssertEqual(all.count, 1)
        let matched = await match(reopened, ";hey")
        XCTAssertEqual(matched, created.id, "the relaunched library feeds the matcher from disk")
    }

    // MARK: Derived state

    func testMatcherFeedSeesCreateRenameDisableDeleteAndUndo() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let before = await match(library, ";hi")
        XCTAssertNil(before)

        let created = try await library.create(name: "Greeting", icon: .emoji("👋"), keyword: ";hi", template: try document("Hello"))
        let afterCreate = await match(library, ";hi")
        XCTAssertEqual(afterCreate, created.id)

        let renamed = try await library.rename(id: created.id, to: "Renamed")
        XCTAssertEqual(renamed.id, created.id, "rename keeps the UUID")
        let afterRename = await match(library, ";hi")
        XCTAssertEqual(afterRename, created.id)

        var rekeyed = renamed
        rekeyed.keyword = ";yo"
        _ = try await library.update(rekeyed)
        let oldKeyword = await match(library, ";hi")
        let newKeyword = await match(library, ";yo")
        XCTAssertNil(oldKeyword)
        XCTAssertEqual(newKeyword, created.id)

        var disabled = rekeyed
        disabled.enabled = false
        _ = try await library.update(disabled)
        let afterDisable = await match(library, ";yo")
        XCTAssertNil(afterDisable)
        _ = try await library.update(rekeyed)
        let afterEnable = await match(library, ";yo")
        XCTAssertEqual(afterEnable, created.id)

        try await library.delete(id: created.id)
        let afterDelete = await match(library, ";yo")
        XCTAssertNil(afterDelete)
        _ = try await library.undoDelete(id: created.id)
        let afterUndo = await match(library, ";yo")
        XCTAssertEqual(afterUndo, created.id)
    }

    func testKeywordConflictSurfacesTypedErrorAndLeavesIndexUntouched() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let first = try await library.create(name: "One", icon: .emoji("1"), keyword: ";dup", template: try document("1"))
        await assertThrowsTyped(StoreError.keywordConflict(existingID: first.id)) {
            _ = try await library.create(name: "Two", icon: .emoji("2"), keyword: ";dup", template: try document("2"))
        }
        let all = await library.allSnippets()
        XCTAssertEqual(all.map(\.id), [first.id])
        let owner = await match(library, ";dup")
        XCTAssertEqual(owner, first.id)
    }

    func testDuplicateIsDisabledCopyAndRestoreFromTrashDisablesOnConflict() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let original = try await library.create(name: "Orig", icon: .emoji("1"), keyword: ";o", template: try document("x"))
        let copy = try await library.duplicate(id: original.id)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(copy.enabled)
        let owner = await match(library, ";o")
        XCTAssertEqual(owner, original.id)

        try await library.delete(id: original.id)
        var taker = copy
        taker.enabled = true
        _ = try await library.update(taker)
        await assertThrowsTyped(StoreError.keywordConflict(existingID: copy.id)) {
            _ = try await library.undoDelete(id: original.id)
        }
        let restored = try await library.restore(id: original.id)
        XCTAssertFalse(restored.enabled)
        let trash = try await library.deletedSnippets()
        XCTAssertTrue(trash.isEmpty)
        let still = await match(library, ";o")
        XCTAssertEqual(still, copy.id)
    }

    func testSearchReflectsEditsImmediately() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let created = try await library.create(name: "Greeting", icon: .emoji("👋"), keyword: ";hi", tags: ["mail"],
                                               template: try document("Hello there"))
        guard case .results(let hits) = await library.search(query: "hello") else { return XCTFail("expected a hit") }
        XCTAssertEqual(hits.map(\.snippet.id), [created.id])

        _ = try await library.rename(id: created.id, to: "Farewell")
        let oldName = await library.search(query: "greeting")
        XCTAssertEqual(oldName, .noMatches)
        guard case .results(let renamed) = await library.search(query: "farewell") else { return XCTFail("expected a hit") }
        XCTAssertEqual(renamed.first?.field, .namePrefix)

        let stored = await library.snippet(id: created.id)
        var edited = try XCTUnwrap(stored)
        edited.template = try document("Bye")
        _ = try await library.update(edited)
        let oldBody = await library.search(query: "there")
        XCTAssertEqual(oldBody, .noMatches)

        try await library.delete(id: created.id)
        let afterDelete = await library.search(query: "farewell")
        XCTAssertEqual(afterDelete, .emptyLibrary)
    }

    func testFiltersPinnedRecentlyUsedAndTag() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let a = try await library.create(name: "Alpha", icon: .emoji("a"), keyword: nil, tags: ["x"], template: try document("a"))
        let b = try await library.create(name: "Beta", icon: .emoji("b"), keyword: nil, tags: ["x", "y"], template: try document("b"))
        let c = try await library.create(name: "Gamma", icon: .emoji("c"), keyword: nil, template: try document("c"))

        func ids(_ filter: LibraryFilter, query: String = "", tags: Set<String> = []) async -> [UUID] {
            guard case .results(let hits) = await library.search(query: query, tags: tags, filter: filter) else { return [] }
            return hits.map(\.snippet.id)
        }
        let all = await ids(.all)
        XCTAssertEqual(all, [a.id, b.id, c.id])
        let none = await library.search(query: "", filter: .recentlyUsed)
        XCTAssertEqual(none, .noMatches, "nothing used yet: not an empty library")

        _ = try await library.setPinned(true, id: c.id)
        let pinned = await ids(.pinned)
        XCTAssertEqual(pinned, [c.id])

        try await library.recordUsage(id: a.id)
        clock.advance(by: 60)
        try await library.recordUsage(id: b.id)
        let recent = await ids(.recentlyUsed)
        XCTAssertEqual(recent, [b.id, a.id], "most recently used first")

        let tagged = await ids(.tag("y"))
        XCTAssertEqual(tagged, [b.id])
        let both = await ids(.tag("x"), tags: ["y"])
        XCTAssertEqual(both, [b.id], "filter tag and tag set combine with AND")
        let queried = await ids(.tag("x"), query: "alp")
        XCTAssertEqual(queried, [a.id])
        let tags = await library.tags()
        XCTAssertEqual(tags, [TagSummary(tag: "x", count: 2), TagSummary(tag: "y", count: 1)])
    }

    func testKeywordDiagnosticsFlagConflictOverlapAndOversize() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let short = try await library.create(name: "Short", icon: .emoji("s"), keyword: ";a", template: try document("s"))
        let long = try await library.create(name: "Long", icon: .emoji("l"), keyword: ";ab", template: try document("l"))
        let clean = await library.keywordDiagnostics()
        XCTAssertTrue(clean.conflicts.isEmpty)
        XCTAssertEqual(clean.overlaps.map(\.shorterSnippetIDs), [[short.id]])
        XCTAssertEqual(clean.overlaps.map(\.longerSnippetIDs), [[long.id]])
        XCTAssertTrue(clean.oversizeKeywordSnippetIDs.isEmpty)

        let draft = makeSnippet(name: "Draft", keyword: ";a")
        let forDraft = await library.keywordDiagnostics(for: draft)
        XCTAssertEqual(forDraft.conflicts.map(\.keyword), [";a"])
        XCTAssertEqual(Set(forDraft.conflicts.first?.snippetIDs ?? []), [short.id, draft.id])
        let unrelated = await library.keywordDiagnostics(for: makeSnippet(name: "Other", keyword: ";zzz"))
        XCTAssertEqual(unrelated, KeywordDiagnostics(conflicts: [], overlaps: [], oversizeKeywordSnippetIDs: []))

        let huge = makeSnippet(name: "Huge", keyword: String(repeating: "k", count: KeywordIndex.maxKeywordScalars + 1))
        let oversize = await library.keywordDiagnostics(for: huge)
        XCTAssertEqual(oversize.oversizeKeywordSnippetIDs, [huge.id])
        let created = try await library.create(huge)
        let persisted = await library.keywordDiagnostics()
        XCTAssertEqual(persisted.oversizeKeywordSnippetIDs, [created.id])
        let ignored = await match(library, String(repeating: "k", count: KeywordIndex.maxKeywordScalars + 1))
        XCTAssertNil(ignored, "the matcher ignores it, which is what the flag warns about")
    }

    // MARK: Expansion

    func testExpansionPromptsForRepeatedArgumentsThenRenders() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let template = try document(#"Hi {argument name="who"} and {argument name="who"}: {argument name="tone" default="warm" options="warm, cold"}{cursor}!"#)
        let created = try await library.create(name: "Prompted", icon: .emoji("p"), keyword: ";p", template: template)
        let found = library.keywordMatcher.feed(";p")
        let match = try XCTUnwrap(found)

        let needs = try await library.expansion(for: match, environment: environment())
        guard case .needsArguments(let requirements) = needs else { return XCTFail("expected prompts") }
        XCTAssertEqual(requirements.map(\.name), ["who", "tone"], "a repeated name is asked once")
        XCTAssertEqual(requirements[1].defaultValue, "warm")
        XCTAssertEqual(requirements[1].choices, ["warm", "cold"])

        let rendered = try await library.expansion(for: match, arguments: ["who": "Ana", "tone": "cold"], environment: environment())
        guard case .rendered(let output) = rendered else { return XCTFail("expected output") }
        XCTAssertEqual(output.plainText, "Hi Ana and Ana: cold!")
        XCTAssertEqual(output.cursorOffset, "Hi Ana and Ana: cold".utf16.count)

        await assertThrowsTyped(RenderError.choiceNotInOptions(name: "tone")) {
            _ = try await library.expansion(for: match, arguments: ["who": "Ana", "tone": "lukewarm"], environment: self.environment())
        }
        XCTAssertNotNil(created)
    }

    func testExpansionIsDirectWhenNoInputIsNeeded() async throws {
        let library = try await openLibrary(at: try databaseURL())
        _ = try await library.create(name: "Plain", icon: .emoji("p"), keyword: ";d", template: try document(#"On {date format="yyyy-MM-dd"}"#))
        let found = library.keywordMatcher.feed(";d")
        let outcome = try await library.expansion(for: try XCTUnwrap(found), environment: environment())
        guard case .rendered(let output) = outcome else { return XCTFail("expected direct expansion") }
        XCTAssertEqual(output.plainText, "On 2026-01-15")
    }

    func testExpansionOfAMatchForAVanishedSnippetIsNotFound() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let created = try await library.create(name: "Gone", icon: .emoji("g"), keyword: ";g", template: try document("x"))
        let found = library.keywordMatcher.feed(";g")
        let stale = try XCTUnwrap(found)
        try await library.delete(id: created.id)
        await assertThrowsTyped(StoreError.notFound(id: created.id)) {
            _ = try await library.expansion(for: stale, environment: self.environment())
        }
    }

    func testPreviewRendersAnUnsavedDocumentAndAsksForArguments() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let draft = try document(#"Hello {argument name="who"}"#)
        let needs = try library.preview(for: draft, environment: environment())
        guard case .needsArguments(let requirements) = needs else { return XCTFail("expected prompts") }
        XCTAssertEqual(requirements.map(\.name), ["who"])
        let rendered = try library.preview(for: draft, arguments: ["who": "Ana"], environment: environment())
        guard case .rendered(let output) = rendered else { return XCTFail("expected output") }
        XCTAssertEqual(output.plainText, "Hello Ana")
        let stored = await library.allSnippets()
        XCTAssertTrue(stored.isEmpty, "preview never saves")
    }

    // MARK: Changes and concurrency

    func testChangesStreamReportsEachCommittedMutationInOrder() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let created = try await library.create(name: "A", icon: .emoji("a"), keyword: ";a", template: try document("a"))
        _ = try await library.rename(id: created.id, to: "B")
        _ = try await library.setPinned(true, id: created.id)
        try await library.recordUsage(id: created.id)
        try await library.delete(id: created.id)
        _ = try await library.undoDelete(id: created.id)
        await assertThrowsTyped(StoreError.notFound(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!)) {
            _ = try await library.rename(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!, to: "x")
        }
        await library.close()

        var seen: [LibraryChange] = []
        for await change in library.changes { seen.append(change) }
        XCTAssertEqual(seen, [.created(created.id), .updated(created.id), .updated(created.id), .usageRecorded(created.id),
                              .deleted(created.id), .restored(created.id)], "a failed write publishes nothing")
    }

    func testConcurrentEditsKeepIndexAndSnapshotConsistent() async throws {
        let url = try databaseURL()
        let library = try await openLibrary(at: url)
        let count = 24
        let templateDocument = try document("body")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<count {
                group.addTask {
                    _ = try await library.create(name: "Snippet \(number)", icon: .emoji("s"), keyword: ";k\(number)x",
                                                 template: templateDocument)
                }
            }
            try await group.waitForAll()
        }
        let created = await library.allSnippets()
        XCTAssertEqual(created.count, count)
        for snippet in created {
            let matched = await match(library, snippet.keyword ?? "")
            XCTAssertEqual(matched, snippet.id)
        }

        // Deletes and a same-keyword race in flight together: the derived state ends up equal to the stored state.
        let deleted = created.prefix(8).map(\.id)
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for number in 0..<6 {
                group.addTask {
                    (try? await library.create(name: "Racer \(number)", icon: .emoji("r"), keyword: ";race", template: templateDocument)) != nil
                }
            }
            for id in deleted {
                group.addTask { (try? await library.delete(id: id)) != nil }
            }
            var outcomes: [Bool] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        XCTAssertEqual(results.filter { $0 }.count, 1 + deleted.count, "one racer wins the keyword; every delete lands")

        let live = await library.allSnippets()
        XCTAssertEqual(live.count, count - deleted.count + 1)
        for snippet in live {
            let matched = await match(library, snippet.keyword ?? "")
            XCTAssertEqual(matched, snippet.id, "live keyword matches its snippet")
        }
        for snippet in created.prefix(8) {
            let matched = await match(library, snippet.keyword ?? "")
            XCTAssertNil(matched, "deleted keyword no longer matches")
        }
        await library.close()
        let reopened = try await openLibrary(at: url)
        let persisted = await reopened.allSnippets()
        XCTAssertEqual(Set(persisted.map(\.id)), Set(live.map(\.id)), "the swapped state is what was committed")
    }


    // MARK: Canonical keywords and undecodable rows

    func testComposedAndDecomposedKeywordsCannotBothBeEnabled() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let first = try await library.create(name: "A", icon: .emoji("a"), keyword: "caf\u{e9}", template: try document("A"))
        await assertThrowsTyped(StoreError.keywordConflict(existingID: first.id)) {
            _ = try await self.library(library, createKeyword: "cafe\u{301}")
        }
        let typedMatch = await match(library, "cafe\u{301}")
        XCTAssertEqual(typedMatch, first.id)
        let diagnostics = await library.keywordDiagnostics()
        XCTAssertTrue(diagnostics.conflicts.isEmpty)
    }

    private func library(_ library: SnippetLibrary, createKeyword keyword: String) async throws -> Snippet {
        try await library.create(name: "B", icon: .emoji("b"), keyword: keyword, template: try document("B"))
    }

    func testLibraryLoadsAndMatchesAroundAnUndecodableRow() async throws {
        let url = try databaseURL()
        let library = try await openLibrary(at: url)
        let good = try await library.create(name: "Good", icon: .emoji("g"), keyword: ";good", template: try document("G"))
        await library.close()
        let bad = UUID()
        try RawDatabase(url).execute("""
        INSERT INTO snippets (id, name, icon_kind, icon_value, keyword, enabled, revision, template, created_at, updated_at)
        VALUES ('\(bad.uuidString)', 'bad', 'emoji', 'x', ';bad', 1, 1, CAST('{"schemaVersion":99,"paragraphs":[]}' AS BLOB), 0, 0)
        """)

        let reopened = try await openLibrary(at: url)
        let listed = await reopened.allSnippets()
        XCTAssertEqual(listed.map(\.id), [good.id])
        let matched = await match(reopened, ";good")
        XCTAssertEqual(matched, good.id)
        let notMatched = await match(reopened, ";bad")
        XCTAssertNil(notMatched)
        let unreadable = await reopened.unreadableRecords()
        XCTAssertEqual(unreadable, [UnreadableRecord(rowID: bad.uuidString, isDeleted: false)])
        try await reopened.delete(id: bad)
        let afterDeleteUnreadable = await reopened.unreadableRecords()
        XCTAssertEqual(afterDeleteUnreadable, [UnreadableRecord(rowID: bad.uuidString, isDeleted: true)])
        let afterDelete = await reopened.allSnippets()
        XCTAssertEqual(afterDelete.map(\.id), [good.id])
    }


    func testInteriorKeywordShadowingIsADiagnostic() async throws {
        let library = try await openLibrary(at: try databaseURL())
        let inner = try await library.create(name: "In", icon: .emoji("i"), keyword: "ab", template: try document("I"))
        let wrapped = try await library.create(name: "Out", icon: .emoji("o"), keyword: ";ab;", template: try document("O"))
        let all = await library.keywordDiagnostics()
        XCTAssertEqual(all.overlaps.map(\.kind), [.contains])
        XCTAssertEqual(all.overlaps.first?.shorterSnippetIDs, [inner.id])
        XCTAssertEqual(all.overlaps.first?.longerSnippetIDs, [wrapped.id])
        let forDraft = await library.keywordDiagnostics(for: wrapped)
        XCTAssertEqual(forDraft.overlaps, all.overlaps)
    }
}

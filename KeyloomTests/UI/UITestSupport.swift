import Foundation
import XCTest
@testable import Keyloom

/// A real library over a temp database, with a fake clock and sequential IDs (no mocks of the library itself).
@MainActor
class LibraryUITestCase: StoreTestCase {
    func openLibrary(at directory: URL? = nil) async throws -> SnippetLibrary {
        let directory = try directory ?? makeDirectory()
        return try await SnippetLibrary(url: directory.appendingPathComponent("keyloom.sqlite"),
                                        backupDirectory: directory.appendingPathComponent("backups"),
                                        now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
    }

    func document(_ source: String) throws -> Document { try TokenParser.parse(source).document }

    @discardableResult
    func seed(_ library: SnippetLibrary, _ name: String, keyword: String? = nil, tags: [String] = [],
              body: String = "Body", pinned: Bool = false) async throws -> Snippet {
        var snippet = try await library.create(name: name, icon: .emoji("🙂"), keyword: keyword, tags: tags, template: try document(body))
        if pinned { snippet = try await library.setPinned(true, id: snippet.id) }
        return snippet
    }
}

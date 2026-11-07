import Foundation

/// Versioned, all-fields interchange: `{"format": "keyloom-snippets", "formatVersion": 1, "exportedAt", "snippets": [...]}`
/// where each snippet is the full `Snippet` (id, revision, tags, pin, icon, dates, usage and the formatted
/// `Document`). Dates are seconds since 1970 as doubles, so they round-trip exactly.
///
/// Forward compatibility: the header is read first and a `formatVersion` above `currentVersion` is refused
/// before the body is looked at. Entries decode one by one, so a damaged entry is listed, not fatal.
enum NativeFormat {
    static let formatName = "keyloom-snippets"
    static let currentVersion = 1

    private struct Header: Decodable {
        let format: String
        let formatVersion: Int
    }

    private struct File: Encodable {
        let format = NativeFormat.formatName
        let formatVersion = NativeFormat.currentVersion
        let exportedAt: Date
        let snippets: [Snippet]
    }

    private struct Body: Decodable {
        let snippets: [Entry]
    }

    /// Decodes one entry and keeps the failure instead of throwing, so one bad entry cannot abort the file.
    private struct Entry: Decodable {
        let result: Result<Snippet, MalformedReason>

        init(from decoder: Decoder) throws {
            do {
                var snippet = try decoder.singleValueContainer().decode(Snippet.self)
                snippet.keyword = SnippetStore.canonical(snippet.keyword)
                try SnippetStore.validate(snippet)
                result = .success(snippet)
            } catch let error as KeyloomError {
                switch error {
                case .unsupportedSchemaVersion(let found, _): result = .failure(.unsupportedDocumentVersion(found: found))
                case .invalidSnippet(let field, _): result = .failure(.invalidField(field))
                default: result = .failure(.invalidDocument)
                }
            } catch {
                result = .failure(.invalidStructure)
            }
        }
    }

    static func export(_ snippets: [Snippet], exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(exportedAt: exportedAt, snippets: snippets))
    }

    static func decode(_ data: Data) throws -> DecodedImport {
        try ImportFileGuard.check(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch DecodingError.dataCorrupted where looksLikeJSON(data) {
            throw PortabilityError.malformedFile
        } catch {
            throw PortabilityError.notRecognized
        }
        guard header.format == formatName else { throw PortabilityError.notRecognized }
        guard header.formatVersion <= currentVersion else {
            throw PortabilityError.unsupportedFormatVersion(found: header.formatVersion, supported: currentVersion)
        }
        guard header.formatVersion >= 1, let body = try? decoder.decode(Body.self, from: data) else {
            throw PortabilityError.malformedFile
        }
        try ImportFileGuard.check(entryCount: body.snippets.count)

        var candidates: [ImportCandidate] = []
        var malformed: [MalformedEntry] = []
        for (index, entry) in body.snippets.enumerated() {
            switch entry.result {
            case .success(let snippet):
                candidates.append(ImportCandidate(index: index, snippet: snippet, unsupportedTokens: snippet.unsupportedTokenSources,
                                                  templateKeptLiteral: false))
            case .failure(let reason):
                malformed.append(MalformedEntry(index: index, reason: reason))
            }
        }
        return DecodedImport(format: .keyloom, candidates: candidates, malformed: malformed)
    }

    /// A truncated file is damaged; arbitrary bytes are simply not ours.
    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !" \t\r\n".utf8.contains($0) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }
}

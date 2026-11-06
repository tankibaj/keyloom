import Foundation

/// Bounds enforced on every document that crosses a trust boundary (decode, import, sync).
enum DocumentLimits {
    static let maxEncodedBytes = 1_048_576
    static let maxParagraphs = 2_000
    static let maxSpans = 20_000
    /// UTF-8 bytes of literal text plus token source, summed over the document.
    static let maxTextBytes = 262_144
    static let maxChoices = 100
}

struct TextStyle: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int
    static let bold = TextStyle(rawValue: 1 << 0)
    static let italic = TextStyle(rawValue: 1 << 1)
    static let underline = TextStyle(rawValue: 1 << 2)
    static let all: TextStyle = [.bold, .italic, .underline]
}

/// Kinds are parsed by the token parser; the model only stores them. `nil` formats mean the default.
enum TokenKind: Codable, Sendable, Hashable {
    case date(format: String?)
    case time(format: String?)
    case uuid
    case clipboard
    case argument(name: String, defaultValue: String?, choices: [String])
    case cursor
    case unsupported(raw: String)
}

/// `raw` is the exact source text, so unsupported or edited tokens survive a round trip. A token takes
/// the style of its enclosing `Run`, and so does the value substituted for it.
struct Token: Codable, Sendable, Hashable {
    var kind: TokenKind
    var raw: String
}

enum TemplateSpan: Codable, Sendable, Hashable {
    case literal(String)
    case token(Token)
}

struct Run: Codable, Sendable, Hashable {
    var style: TextStyle
    var spans: [TemplateSpan]
}

enum ParagraphKind: String, Codable, Sendable, Hashable {
    case plain, bullet, numbered
}

/// Numbered items are numbered at render time from consecutive `.numbered` paragraphs.
struct Paragraph: Codable, Sendable, Hashable {
    var kind: ParagraphKind
    var runs: [Run]
}

struct Document: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1

    private(set) var schemaVersion: Int
    var paragraphs: [Paragraph]

    init(paragraphs: [Paragraph]) {
        schemaVersion = Self.currentSchemaVersion
        self.paragraphs = paragraphs
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, paragraphs }

    /// Checks the version before reading the body, so a newer document fails as a version error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw KeyloomError.unsupportedSchemaVersion(found: version, supported: Self.currentSchemaVersion)
        }
        schemaVersion = version
        paragraphs = try container.decode([Paragraph].self, forKey: .paragraphs)
        try validate()
    }

    func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> Document {
        guard data.count <= DocumentLimits.maxEncodedBytes else {
            throw KeyloomError.documentTooLarge(limit: "encodedBytes", maximum: DocumentLimits.maxEncodedBytes)
        }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch let error as KeyloomError {
            throw error
        } catch {
            throw KeyloomError.malformedDocument(reason: "unreadable document structure")
        }
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw KeyloomError.unsupportedSchemaVersion(found: schemaVersion, supported: Self.currentSchemaVersion)
        }
        guard paragraphs.count <= DocumentLimits.maxParagraphs else {
            throw KeyloomError.documentTooLarge(limit: "paragraphs", maximum: DocumentLimits.maxParagraphs)
        }
        var spanCount = 0
        var textBytes = 0
        var cursors = 0
        for run in paragraphs.flatMap(\.runs) {
            guard TextStyle.all.contains(run.style) else {
                throw KeyloomError.malformedDocument(reason: "unknown style bits")
            }
            spanCount += run.spans.count
            guard spanCount <= DocumentLimits.maxSpans else {
                throw KeyloomError.documentTooLarge(limit: "spans", maximum: DocumentLimits.maxSpans)
            }
            for span in run.spans {
                switch span {
                case .literal(let text):
                    textBytes += text.utf8.count
                case .token(let token):
                    textBytes += token.raw.utf8.count
                    switch token.kind {
                    case .cursor:
                        cursors += 1
                    case .argument(_, _, let choices) where choices.count > DocumentLimits.maxChoices:
                        throw KeyloomError.documentTooLarge(limit: "choices", maximum: DocumentLimits.maxChoices)
                    default:
                        break
                    }
                }
                guard textBytes <= DocumentLimits.maxTextBytes else {
                    throw KeyloomError.documentTooLarge(limit: "textBytes", maximum: DocumentLimits.maxTextBytes)
                }
            }
        }
        guard cursors <= 1 else { throw KeyloomError.multipleCursors(count: cursors) }
    }

    /// Text for search: literals and token source verbatim, paragraphs joined by newlines, no list markers.
    var plainText: String {
        paragraphs.map { paragraph in
            paragraph.runs.flatMap(\.spans).map { span -> String in
                switch span {
                case .literal(let text): text
                case .token(let token): token.raw
                }
            }.joined()
        }.joined(separator: "\n")
    }
}

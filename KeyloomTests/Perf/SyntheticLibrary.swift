import Foundation
@testable import Keyloom

/// SplitMix64: a tiny seeded generator, so fixtures are identical on every run and machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Deterministic synthetic library for performance and footprint profiling: names, keywords, tags, tokens,
/// styles and Unicode vary, and body text sums to about `targetBytes`. Synthetic text only, never user data.
enum SyntheticLibrary {
    static let defaultSeed: UInt64 = 0x4B45_594C_4F4F_4D01
    static let defaultCount = 1_000
    /// Total body size: UTF-8 bytes of every snippet's `plainText`, about 1 MiB.
    static let defaultTargetBytes = 1_048_576
    static let databaseName = "keyloom.sqlite"
    static let backupsName = "backups"
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    enum WriteError: Error, Equatable {
        /// Refuses to touch a directory that already holds a library, so a real one is never overwritten.
        case libraryAlreadyExists(String)
    }

    private static let words = [
        "alpha", "invoice", "meeting", "follow-up", "Grüße", "Straße", "naïve", "façade", "résumé", "señor", "café",
        "日本語", "こんにちは", "Привет", "مرحبا", "שלום", "αβγ", "😀", "👩‍💻", "🇩🇪", "e\u{301}clair", "schedule", "quarterly",
        "report", "regards", "thanks", "please", "review", "attached", "deadline", "customer", "ticket", "deploy",
        "release", "patient", "appointment", "prescription", "reminder", "agenda", "summary", "action", "item",
    ]
    private static let adjectives = ["Quick", "Formal", "Friendly", "Short", "Long", "Weekly", "Urgent", "Polite", "Über", "Café"]
    private static let nouns = ["reply", "greeting", "signature", "note", "intro", "outro", "template", "answer", "日本語", "😀 mood"]
    private static let tagPool = [
        "work", "mail", "personal", "support", "sales", "dev", "ops", "legal", "hr", "finance", "café", "über", "日本語",
        "2026", "q1", "q2", "q3", "q4", "draft", "final", "internal", "external", "clinic", "billing", "docs", "chat",
        "review", "weekly", "daily", "misc",
    ]
    private static let keywordPrefixes = [";", "::", "//", ";ü", "🔑"]
    private static let styles: [TextStyle] = [[], [], [], .bold, .italic, .underline, [.bold, .italic], .all]
    private static let symbols = ["text.bubble", "envelope", "star", "doc.text", "tag"]
    private static let emojis = ["👋", "📧", "✅", "🗓️", "💬"]

    /// `count` snippets whose body sizes sum to about `targetBytes`. Keywords are unique; about one in ten has none.
    static func snippets(seed: UInt64 = defaultSeed, count: Int = defaultCount, targetBytes: Int = defaultTargetBytes) -> [Snippet] {
        var rng = SeededGenerator(seed: seed)
        let weights = (0..<count).map { _ in 0.25 + 1.5 * Double.random(in: 0..<1, using: &rng) }
        let weightSum = weights.reduce(0, +)
        return (0..<count).map { index in
            snippet(index: index, bodyBytes: Int(Double(targetBytes) * weights[index] / weightSum), rng: &rng)
        }
    }

    /// Creates `directory` if needed and writes the snippets through the real `SnippetStore`. Returns the
    /// database URL (`directory/keyloom.sqlite`, backups in `directory/backups`).
    @discardableResult
    static func write(to directory: URL, seed: UInt64 = defaultSeed, count: Int = defaultCount,
                      targetBytes: Int = defaultTargetBytes) async throws -> URL {
        let database = directory.appendingPathComponent(databaseName)
        guard !FileManager.default.fileExists(atPath: database.path) else {
            throw WriteError.libraryAlreadyExists(directory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SnippetStore(url: database, backupDirectory: directory.appendingPathComponent(backupsName),
                                     now: { epoch }, makeID: { UUID() })
        for snippet in snippets(seed: seed, count: count, targetBytes: targetBytes) {
            _ = try await store.create(snippet)
        }
        await store.close()
        return database
    }

    // MARK: Private

    private static func snippet(index: Int, bodyBytes: Int, rng: inout SeededGenerator) -> Snippet {
        let id = uuid(&rng)
        let name = "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!) \(index)"
        let icon: SnippetIcon = index.isMultiple(of: 2) ? .emoji(emojis.randomElement(using: &rng)!)
                                                         : .symbol(symbols.randomElement(using: &rng)!)
        let tags = Array(Set((0..<Int.random(in: 0...4, using: &rng)).map { _ in tagPool.randomElement(using: &rng)! })).sorted()
        return Snippet(id: id, name: name, icon: icon, keyword: keyword(index: index), enabled: !index.isMultiple(of: 25),
                       tags: tags, pinned: index.isMultiple(of: 50),
                       template: body(bytes: bodyBytes, allowsArguments: index.isMultiple(of: 4), rng: &rng),
                       createdAt: epoch.addingTimeInterval(TimeInterval(index)))
    }

    private static func uuid(_ rng: inout SeededGenerator) -> UUID {
        let hex = [rng.next(), rng.next()].map { String($0, radix: 16, uppercase: true) }
            .map { String(repeating: "0", count: 16 - $0.count) + $0 }.joined()
        let chars = Array(hex)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    /// Unique per index: a prefix chosen by index, then three base-36 digits of it. No keyword is a prefix,
    /// suffix or interior part of another, so typing one never shadows another (checked in the tests).
    private static func keyword(index: Int) -> String? {
        guard index % 10 != 9 else { return nil }
        let digits = String(index, radix: 36)
        return keywordPrefixes[index % keywordPrefixes.count] + String(repeating: "0", count: 3 - digits.count) + digits
    }

    private static func body(bytes: Int, allowsArguments: Bool, rng: inout SeededGenerator) -> Document {
        var paragraphs: [Paragraph] = []
        var used = 0
        var placedCursor = false
        while used < bytes {
            let kind: ParagraphKind = [.plain, .plain, .plain, .plain, .bullet, .numbered].randomElement(using: &rng)!
            var runs: [Run] = []
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                var source = ""
                for _ in 0..<Int.random(in: 3...14, using: &rng) {
                    let piece = Int.random(in: 0..<40, using: &rng) == 0
                        ? token(allowsArguments: allowsArguments, cursorPlaced: &placedCursor, rng: &rng)
                        : words.randomElement(using: &rng)! + " "
                    guard used + source.utf8.count + piece.utf8.count <= bytes else { break }
                    source += piece
                }
                guard !source.isEmpty else { break }
                used += source.utf8.count
                // Parsed, not hand-built, so token kinds and raw source match what the editor produces.
                let spans = (try? TokenParser.parse(source).document.paragraphs.first?.runs.first?.spans) ?? [.literal(source)]
                runs.append(Run(style: styles.randomElement(using: &rng)!, spans: spans))
            }
            guard !runs.isEmpty else { break }
            paragraphs.append(Paragraph(kind: kind, runs: runs))
            used += 1
        }
        return Document(paragraphs: paragraphs.isEmpty ? [Paragraph(kind: .plain, runs: [])] : paragraphs)
    }

    private static func token(allowsArguments: Bool, cursorPlaced: inout Bool, rng: inout SeededGenerator) -> String {
        var choices = [#"{date}"#, #"{date format="yyyy-MM-dd"}"#, #"{time}"#, #"{uuid}"#, #"{clipboard}"#, #"{date offset="+1d"}"#]
        if allowsArguments {
            choices += [#"{argument name="who" default="team"}"#, #"{argument name="tone" default="formal" options="formal,casual"}"#]
        }
        if !cursorPlaced { choices.append("{cursor}") }
        let picked = choices.randomElement(using: &rng)!
        if picked == "{cursor}" { cursorPlaced = true }
        return picked + " "
    }
}

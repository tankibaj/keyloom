import Foundation

/// Raycast-compatible snippet interchange.
///
/// Assumed shape (Raycast's "Export Snippets" JSON): a top-level array of objects, each with a string `name`,
/// a string `text` and an optional string `keyword` (absent or empty when the snippet has none). Other keys are
/// ignored. Text uses Raycast placeholders (`{clipboard}`, `{cursor}`, `{date format="..."}`, `{argument ...}`),
/// which `TokenParser` reads; placeholders this build does not know stay in the text literally and are flagged.
/// Raycast carries no id, icon, tags, pin, enabled flag or styling, so export drops them (see `losses(in:)`).
enum RaycastFormat {
    private static let defaultIcon = SnippetIcon.symbol("text.bubble")

    private struct Record: Encodable {
        let name: String
        let text: String
        let keyword: String?
    }

    static func decode(_ data: Data, now: Date, makeID: () -> UUID) throws -> DecodedImport {
        try ImportFileGuard.check(data)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PortabilityError.malformedFile
        }
        guard let records = parsed as? [Any] else { throw PortabilityError.notRecognized }
        try ImportFileGuard.check(entryCount: records.count)

        var candidates: [ImportCandidate] = []
        var malformed: [MalformedEntry] = []
        for (index, record) in records.enumerated() {
            switch candidate(index: index, record: record, now: now, makeID: makeID) {
            case .success(let candidate): candidates.append(candidate)
            case .failure(let reason): malformed.append(MalformedEntry(index: index, reason: reason))
            }
        }
        return DecodedImport(format: .raycast, candidates: candidates, malformed: malformed)
    }

    private static func candidate(index: Int, record: Any, now: Date, makeID: () -> UUID) -> Result<ImportCandidate, MalformedReason> {
        guard let fields = record as? [String: Any] else { return .failure(.invalidStructure) }
        guard let rawName = fields["name"] else { return .failure(.missingField("name")) }
        guard let name = rawName as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidField("name"))
        }
        guard let rawText = fields["text"] else { return .failure(.missingField("text")) }
        guard let text = rawText as? String else { return .failure(.invalidField("text")) }
        var keyword: String?
        if let rawKeyword = fields["keyword"], !(rawKeyword is NSNull) {
            guard let value = rawKeyword as? String else { return .failure(.invalidField("keyword")) }
            keyword = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lineBreaksNormalized(value)
        }

        let source = lineBreaksNormalized(text)
        let template: Document
        let keptLiteral: Bool
        do {
            template = try TokenParser.parse(source).document
            keptLiteral = false
        } catch {
            // A stray `{` (code, JSON) is common in snippets: keep the text exactly rather than reject it.
            template = literalDocument(source)
            keptLiteral = true
        }
        let snippet = Snippet(id: makeID(), name: lineBreaksNormalized(name), icon: defaultIcon,
                              keyword: SnippetStore.canonical(keyword), template: template, createdAt: now)
        do {
            try SnippetStore.validate(snippet)
        } catch let error as KeyloomError {
            if case .invalidSnippet(let field, _) = error { return .failure(.invalidField(field)) }
            return .failure(.invalidDocument)
        } catch {
            return .failure(.invalidStructure)
        }
        return .success(ImportCandidate(index: index, snippet: snippet, unsupportedTokens: snippet.unsupportedTokenSources,
                                        templateKeptLiteral: keptLiteral))
    }

    private static func lineBreaksNormalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func literalDocument(_ text: String) -> Document {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            Paragraph(kind: .plain, runs: [Run(style: [], spans: line.isEmpty ? [] : [.literal(String(line))])])
        }
        return Document(paragraphs: paragraphs)
    }

    // MARK: Export

    struct Export: Equatable, Sendable {
        let data: Data
        let losses: [FormattingLoss]
    }

    static func export(_ snippets: [Snippet]) throws -> Export {
        let records = snippets.map { Record(name: $0.name, text: text(of: $0.template), keyword: $0.keyword) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return Export(data: try encoder.encode(records), losses: losses(in: snippets))
    }

    /// What exporting `snippets` drops, per snippet; snippets that lose nothing are not listed.
    static func losses(in snippets: [Snippet]) -> [FormattingLoss] {
        snippets.compactMap { snippet in
            var kinds: Set<LossKind> = []
            let runs = snippet.template.paragraphs.flatMap(\.runs)
            if runs.contains(where: { !$0.style.isEmpty }) { kinds.insert(.textStyles) }
            if snippet.template.paragraphs.contains(where: { $0.kind != .plain }) { kinds.insert(.listFormatting) }
            if !snippet.tags.isEmpty { kinds.insert(.tags) }
            if snippet.pinned { kinds.insert(.pinned) }
            if !snippet.enabled { kinds.insert(.disabled) }
            return kinds.isEmpty ? nil : FormattingLoss(snippetID: snippet.id, kinds: kinds)
        }
    }

    /// Paragraphs joined by newlines, tokens as their exact source, literals escaped the way `TokenParser`
    /// reads them back, so a re-import yields the same spans.
    private static func text(of document: Document) -> String {
        document.paragraphs.map { paragraph in
            let sources: [(text: String, isLiteral: Bool)] = paragraph.runs.flatMap(\.spans).map { span in
                switch span {
                case .literal(let text): (text, true)
                case .token(let token): (token.raw, false)
                }
            }
            return sources.enumerated().map { offset, piece in
                piece.isLiteral ? escaped(piece.text, before: sources[(offset + 1)...].first?.text.unicodeScalars.first) : piece.text
            }.joined()
        }.joined(separator: "\n")
    }

    /// `{` always, and a backslash whenever it would otherwise escape what follows (`{`, `}` or another `\`),
    /// including the first character of the next piece.
    private static func escaped(_ literal: String, before next: Unicode.Scalar?) -> String {
        let scalars = Array(literal.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            let following = index + 1 < scalars.count ? scalars[index + 1] : next
            if scalar == "{" {
                output.append(contentsOf: "\\{".unicodeScalars)
            } else if scalar == "\\", let following, ["{", "}", "\\"].contains(following) {
                output.append(contentsOf: "\\\\".unicodeScalars)
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }
}

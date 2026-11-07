import Foundation
import Observation

/// The editor's unsaved state. Equatable so "dirty" is just "differs from the saved draft".
struct SnippetDraft: Equatable {
    var name = ""
    var icon: SnippetIcon = .symbol("text.bubble")
    var keyword = ""
    var enabled = true
    var tagsText = ""
    var body = Document(paragraphs: [])

    init() {}

    init(_ snippet: Snippet) {
        name = snippet.name
        icon = snippet.icon
        keyword = snippet.keyword ?? ""
        enabled = snippet.enabled
        tagsText = snippet.tags.joined(separator: ", ")
        body = snippet.template
    }

    /// Trimmed, non-empty, first spelling wins.
    var tags: [String] {
        var seen = Set<String>()
        return tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var normalizedKeyword: String? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What the keyword field says about the draft's keyword, judged by the library as if the draft were saved.
struct KeywordFeedback: Equatable {
    /// Another enabled snippet owns the keyword; an enabled draft cannot be saved.
    var conflicts: [String] = []
    /// Overlaps and ignored keywords: worth knowing, never blocking.
    var warnings: [String] = []

    var blocksEnabling: Bool { !conflicts.isEmpty }
}

enum Preview: Equatable {
    case rendered(RenderedSnippet)
    case unavailable(String)
}

/// One editing session: a new draft or an existing snippet. Saving goes through `SnippetLibrary`; typing in the
/// body only updates `draft`.
@MainActor @Observable
final class EditorViewModel {
    enum Target: Equatable {
        case new
        case existing(UUID)
    }

    let library: SnippetLibrary
    let bodyController = RichTextController()
    private(set) var target: Target
    var draft: SnippetDraft
    private(set) var baseline: SnippetDraft
    var errorMessage: String?
    private(set) var keywordFeedback = KeywordFeedback()
    /// Try Expansion: values the user typed for arguments; the rest fall back to default, first choice, then a stand-in.
    var sampleArguments: [String: String] = [:]
    @ObservationIgnored private let draftID = UUID()
    @ObservationIgnored private let environment: @MainActor () -> RenderEnvironment

    /// `environment` supplies the clock, locale and UUIDs for the preview; the clipboard is never read for it.
    init(library: SnippetLibrary, snippet: Snippet?, environment: @escaping @MainActor () -> RenderEnvironment = EditorViewModel.liveEnvironment) {
        self.library = library
        self.environment = environment
        let initial = snippet.map(SnippetDraft.init) ?? SnippetDraft()
        target = snippet.map { .existing($0.id) } ?? .new
        baseline = initial
        draft = initial
        bodyController.onChange = { [weak self] in self?.draft.body = $0 }
        bodyController.load(initial.body)
    }

    static func liveEnvironment() -> RenderEnvironment {
        RenderEnvironment(date: Date(), timeZone: .current, locale: .current, makeUUID: { UUID() }, clipboardText: { "Clipboard text" })
    }

    var isDirty: Bool { draft != baseline }
    var canSave: Bool {
        isDirty && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(draft.enabled && keywordFeedback.blocksEnabling)
    }

    var argumentRequirements: [ArgumentRequirement] { TemplateRenderer.requiredArguments(in: draft.body) }

    /// Asks the library about the draft's keyword. Call when the keyword or the enabled switch changes.
    func refreshKeywordFeedback() async {
        guard draft.enabled, let keyword = draft.normalizedKeyword else {
            keywordFeedback = KeywordFeedback()
            return
        }
        let id: UUID
        if case .existing(let existing) = target { id = existing } else { id = draftID }
        let probe = Snippet(id: id, name: draft.name, icon: draft.icon, keyword: keyword, template: draft.body, createdAt: Date())
        let diagnostics = await library.keywordDiagnostics(for: probe)
        var names: [UUID: String] = [:]
        let others = Set(diagnostics.conflicts.flatMap(\.snippetIDs) + diagnostics.overlaps.flatMap { $0.shorterSnippetIDs + $0.longerSnippetIDs }).subtracting([id])
        for other in others { names[other] = await library.snippet(id: other)?.name }
        // The user kept typing while the library answered; the newer call owns the result.
        guard draft.enabled, draft.normalizedKeyword == keyword else { return }
        func list(_ ids: [UUID]) -> String { ids.filter { $0 != id }.compactMap { names[$0] }.map { "“\($0)”" }.joined(separator: ", ") }
        var feedback = KeywordFeedback()
        for conflict in diagnostics.conflicts {
            feedback.conflicts.append("\(list(conflict.snippetIDs)) already expands from \(conflict.keyword).")
        }
        for overlap in diagnostics.overlaps {
            let thisIsShorter = overlap.shorterSnippetIDs.contains(id)
            let other = list(thisIsShorter ? overlap.longerSnippetIDs : overlap.shorterSnippetIDs)
            switch (overlap.kind, thisIsShorter) {
            case (.prefix, true), (.contains, true):
                feedback.warnings.append("“\(overlap.shorter)” completes first while typing “\(overlap.longer)” (\(other)), so that keyword can never be typed.")
            case (.prefix, false), (.contains, false):
                feedback.warnings.append("“\(overlap.longer)” can never be typed: “\(overlap.shorter)” (\(other)) completes first.")
            case (.suffix, _):
                feedback.warnings.append("“\(overlap.shorter)” also completes at the end of “\(overlap.longer)”; \(thisIsShorter ? "the longer keyword (\(other)) wins there" : "“\(overlap.shorter)” (\(other)) still fires after other text").")
            }
        }
        if !diagnostics.oversizeKeywordSnippetIDs.isEmpty {
            feedback.warnings.append("Keywords longer than \(KeywordIndex.maxKeywordScalars) characters are ignored.")
        }
        keywordFeedback = feedback
    }

    /// Suggests, never requires: `::` keeps ordinary words from expanding by accident.
    var keywordHint: String? {
        guard let keyword = draft.normalizedKeyword, !keyword.hasPrefix("::") else { return nil }
        return "Keywords starting with :: rarely trigger by accident, but any keyword works."
    }

    var preview: Preview {
        let body = draft.body
        let requirements = TemplateRenderer.requiredArguments(in: body)
        let samples = Dictionary(uniqueKeysWithValues: requirements.map {
            ($0.name, sampleArguments[$0.name] ?? $0.defaultValue ?? $0.choices.first ?? "‹\($0.name)›")
        })
        do {
            switch try library.preview(for: body, arguments: samples, environment: environment()) {
            case .rendered(let rendered): return .rendered(rendered)
            case .needsArguments: return .unavailable("Sample values are missing.")
            }
        } catch {
            return .unavailable(UserMessage.describe(error))
        }
    }

    /// Stores the draft: a new snippet, or the edits on the existing one (same ID). On failure the edits stay.
    func save() async -> Bool {
        errorMessage = nil
        guard canSave else {
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "Give the snippet a name before saving."
            } else if draft.enabled, let conflict = keywordFeedback.conflicts.first {
                errorMessage = conflict
            }
            return false
        }
        do {
            try draft.body.validate()
            let saved: Snippet
            switch target {
            case .new:
                saved = try await library.create(name: draft.name, icon: draft.icon, keyword: draft.normalizedKeyword, enabled: draft.enabled,
                                                 tags: draft.tags, template: draft.body)
            case .existing(let id):
                guard var current = await library.snippet(id: id) else { throw StoreError.notFound(id: id) }
                // Only what the user changed since the editor loaded: a field edited elsewhere meanwhile (sync)
                // keeps its stored value unless the user also edited it, in which case the user's edit wins.
                if draft.name != baseline.name { current.name = draft.name }
                if draft.icon != baseline.icon { current.icon = draft.icon }
                if draft.keyword != baseline.keyword { current.keyword = draft.normalizedKeyword }
                if draft.enabled != baseline.enabled { current.enabled = draft.enabled }
                if draft.tagsText != baseline.tagsText { current.tags = draft.tags }
                if draft.body != baseline.body { current.template = draft.body }
                saved = try await library.update(current)
            }
            target = .existing(saved.id)
            let merged = SnippetDraft(saved)
            let bodyChanged = merged.body != draft.body
            baseline = merged
            draft = merged
            if bodyChanged { bodyController.load(merged.body) }
            return true
        } catch {
            errorMessage = UserMessage.describe(error)
            if case StoreError.keywordConflict = error { await refreshKeywordFeedback() }
            return false
        }
    }

    /// The stored snippet changed (sync, another window, an import). A clean editor shows the new version; a dirty
    /// one keeps the user's draft and its baseline, so `save` can tell what the user actually edited.
    func refreshFromLibrary() async {
        guard case .existing(let id) = target, let stored = await library.snippet(id: id) else { return }
        let latest = SnippetDraft(stored)
        guard latest != baseline, draft == baseline else { return }
        baseline = latest
        draft = latest
        bodyController.load(latest.body)
        await refreshKeywordFeedback()
    }

    /// Drops unsaved edits, including those in the text view.
    func revert() {
        draft = baseline
        errorMessage = nil
        bodyController.load(baseline.body)
    }
}

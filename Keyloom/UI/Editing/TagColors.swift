import Foundation
import Observation
import SwiftUI

/// The tag palette: the system accent-style colors. A tag with no color is drawn gray.
enum TagColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// Tag colors: a device-local preference, never synced and not part of the store. A JSON map in the app's defaults,
/// keyed by the tag's normalized name (trimmed, canonically composed, lowercased). Tag names are never logged.
@MainActor @Observable
final class TagColors {
    /// Keeps the old `app.keyloom.` prefix, like the other preference keys.
    static let defaultsKey = "app.keyloom.tagColors"

    @ObservationIgnored private let defaults: UserDefaults
    private var assignments: [String: TagColor]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Anything unreadable (missing, corrupt, a color from a newer version) reads as no color.
        let stored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        assignments = stored.compactMapValues { TagColor(rawValue: $0) }
    }

    nonisolated static func normalized(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    func color(for tag: String) -> TagColor? { assignments[Self.normalized(tag)] }

    /// nil clears the color. Choosing the tag's current color again clears it too.
    func set(_ color: TagColor?, for tag: String) {
        let key = Self.normalized(tag)
        guard !key.isEmpty else { return }
        if let color, assignments[key] != color { assignments[key] = color } else { assignments[key] = nil }
        let raw = assignments.mapValues(\.rawValue)
        if raw.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension TagColors {
    /// A renamed tag keeps its color (the old name is cleared, a color already on the new name wins).
    func moveColor(from old: String, to new: String) {
        let target = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let color = color(for: old), !target.isEmpty, TagColors.normalized(old) != TagColors.normalized(target) else { return }
        set(nil, for: old)
        if self.color(for: target) == nil { set(color, for: target) }
    }
}

/// The palette as menu items; the tag's current color is checked, and choosing it again clears it.
struct TagColorMenuItems: View {
    let tag: String
    let colors: TagColors

    var body: some View {
        let current = colors.color(for: tag)
        ForEach(TagColor.allCases) { color in
            Button {
                colors.set(color, for: tag)
            } label: {
                Label(color.displayName, systemImage: current == color ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(color.color)
            }
        }
        if current != nil {
            Divider()
            Button("No Color") { colors.set(nil, for: tag) }
        }
    }
}

/// Which existing tags to offer while a tag is typed.
enum TagSuggestions {
    /// `available` filtered by what is typed (a case-insensitive prefix; nothing typed offers all), without the tags
    /// the snippet already has, in the order given, at most `limit`. Free text is never blocked: a name that is not
    /// offered still creates a new tag.
    static func suggestions(typed: String, available: [String], excluding current: [String], limit: Int = 8) -> [String] {
        let prefix = TagColors.normalized(typed)
        let taken = Set(current.map(TagColors.normalized))
        var seen = Set<String>()
        return available
            .filter { tag in
                let key = TagColors.normalized(tag)
                return !key.isEmpty && !taken.contains(key) && key.hasPrefix(prefix) && seen.insert(key).inserted
            }
            .prefix(limit)
            .map { $0 }
    }
}

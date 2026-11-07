import Foundation

/// Identity of the focused field. `element` is an id from `ElementIdentityCache`, stable while the same
/// Accessibility element is still remembered, never reused for a different one.
struct FocusToken: Equatable, Sendable {
    let pid: Int32
    let element: Int
}

/// Everything verified about a field at one instant. Text is held in memory only for the length of one
/// insertion, never stored or logged.
struct FieldSnapshot: Equatable, Sendable {
    var token: FocusToken
    var bundleID: String?
    var role: String
    var isSecure: Bool
    var text: String?
    var selection: NSRange?

    /// Same element, app, role and exact value as `bound`. A nil bound selection leaves the caret free (used
    /// once our own write has moved it).
    func satisfies(_ bound: FieldSnapshot) -> Bool {
        token == bound.token && bundleID == bound.bundleID && role == bound.role && isSecure == bound.isSecure
            && text == bound.text && (bound.selection == nil || selection == bound.selection)
    }
}

enum WriteResult: Equatable, Sendable {
    case written, destinationChanged, failed
}

/// The focused text field of another app. Every method re-reads live state; nothing is cached but identity.
@MainActor
protocol DestinationAccess: AnyObject {
    /// Cheap identity of the focused field; nil when nothing usable has focus.
    func focusToken() -> FocusToken?
    /// Full state of the focused field; nil when it cannot be read.
    func snapshot() -> FieldSnapshot?
    /// Brings the field's application back to the front. True once that same field has focus again.
    func activate(_ token: FocusToken) async -> Bool
    /// Each write re-reads the live field right before touching it and, unless it still satisfies `bound`,
    /// returns `.destinationChanged` having written nothing. Writes act on the element just verified, never
    /// on whatever is focused later.
    func replace(range: NSRange, with text: String, bound: FieldSnapshot) -> WriteResult
    func select(_ range: NSRange, bound: FieldSnapshot) -> WriteResult
}

/// Maps live elements to small stable ids, so focus returning to an earlier element yields the same token
/// (needed when Keyloom's own prompt briefly holds focus). Bounded; an evicted element gets a fresh id.
struct ElementIdentityCache<Element> {
    private let capacity: Int
    private let same: (Element, Element) -> Bool
    private var entries: [(element: Element, id: Int)] = []
    private var nextID = 0

    init(capacity: Int, same: @escaping (Element, Element) -> Bool) {
        self.capacity = capacity
        self.same = same
    }

    mutating func id(for element: Element) -> Int {
        if let known = entries.first(where: { same($0.element, element) }) { return known.id }
        nextID += 1
        entries.append((element, nextID))
        if entries.count > capacity { entries.removeFirst() }
        return nextID
    }
}

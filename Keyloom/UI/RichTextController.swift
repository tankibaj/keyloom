import AppKit
import Observation

/// Owns the editor's `NSTextView` behavior: formatting commands, lists, atomic token chips, and publishing the
/// `Document` after each edit. Loading a document never publishes, and typing touches no library or store.
@MainActor @Observable
final class RichTextController: NSObject, NSTextViewDelegate {
    private(set) var activeStyles: TextStyle = []
    private(set) var activeKind: ParagraphKind = .plain
    /// A document holds at most one cursor marker, so Insert Placeholder offers it only while this is false.
    private(set) var hasCursorToken = false
    @ObservationIgnored var onChange: (@MainActor (Document) -> Void)?
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var editMayCompleteToken = false

    @ObservationIgnored private var pendingDocument: Document?

    /// What the system's Writing Tools may do in the body. Off until the policy says otherwise.
    var writingToolsBehavior: EditorWritingToolsBehavior = .none {
        didSet { textView?.writingToolsBehavior = Self.nsBehavior(writingToolsBehavior) }
    }

    static func nsBehavior(_ behavior: EditorWritingToolsBehavior) -> NSWritingToolsBehavior {
        switch behavior {
        case .none: NSWritingToolsBehavior.none
        case .default: NSWritingToolsBehavior.default
        }
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.writingToolsBehavior = Self.nsBehavior(writingToolsBehavior)
        textView.delegate = self
        if let pendingDocument { load(pendingDocument) }
    }

    /// Replaces the text with `document` and does not publish. Before a text view is attached it is kept until one is.
    func load(_ document: Document) {
        pendingDocument = document
        guard let textView, let storage = textView.textStorage else { return }
        pendingDocument = nil
        isApplying = true
        defer { isApplying = false }
        storage.setAttributedString(RichTextConverter.attributedString(from: document))
        textView.typingAttributes = RichTextConverter.attributes(style: [], kind: .plain)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        hasCursorToken = Self.containsCursor(document)
        refreshState()
    }

    // MARK: Commands

    func toggle(_ style: TextStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            var typing = textView.typingAttributes
            Self.apply(RichTextConverter.style(of: typing).symmetricDifference(style), to: &typing)
            textView.typingAttributes = typing
            refreshState()
            return
        }
        var runs: [(NSRange, TextStyle)] = []
        storage.enumerateAttributes(in: selection) { attributes, range, _ in runs.append((range, RichTextConverter.style(of: attributes))) }
        let removing = runs.allSatisfy { $0.1.contains(style) }
        edit(selection) { storage in
            for (range, current) in runs {
                var attributes: [NSAttributedString.Key: Any] = [:]
                Self.apply(removing ? current.subtracting(style) : current.union(style), to: &attributes)
                storage.addAttribute(.font, value: attributes[.font]!, range: range)
                if let underline = attributes[.underlineStyle] {
                    storage.addAttribute(.underlineStyle, value: underline, range: range)
                } else {
                    storage.removeAttribute(.underlineStyle, range: range)
                }
            }
        }
        refreshState()
    }

    /// Sets the kind of every paragraph in the selection; choosing the caret paragraph's current kind clears it.
    func setKind(_ kind: ParagraphKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let target: ParagraphKind = activeKind == kind ? .plain : kind
        let selection = textView.selectedRange()
        let paragraphs = RichTextConverter.paragraphRanges(in: storage.string).filter {
            $0.location <= selection.upperBound && $0.upperBound >= selection.location && !(selection.length > 0 && $0.location == selection.upperBound)
        }
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let whole = NSRange(location: first.location, length: min(last.upperBound + 1, storage.length) - first.location)
        let anchors = (anchor(selection.location), anchor(selection.upperBound))
        edit(whole) { storage in
            for paragraph in paragraphs.reversed() { Self.setKind(target, on: paragraph, in: storage) }
        }
        restoreSelection(anchors)
    }

    /// Inserts a chip for `source` at the selection, in the style of the text around it.
    func insert(tokenSource source: String) {
        guard let textView else { return }
        let attributes = RichTextConverter.attributes(style: RichTextConverter.style(of: textView.typingAttributes), kind: activeKind, isToken: true)
        textView.insertText(NSAttributedString(string: source, attributes: attributes), replacementRange: textView.selectedRange())
        sanitizeTypingAttributes()
    }

    private static func apply(_ style: TextStyle, to attributes: inout [NSAttributedString.Key: Any]) {
        let fresh = RichTextConverter.attributes(style: style, kind: .plain)
        attributes[.font] = fresh[.font]
        attributes[.underlineStyle] = fresh[.underlineStyle]
    }

    /// Replaces any list marker on `paragraph` and tags the paragraph; `normalizeLists` fixes the marker text.
    private static func setKind(_ kind: ParagraphKind, on paragraph: NSRange, in storage: NSTextStorage) {
        let marker = NSRange(location: paragraph.location, length: RichTextConverter.markerLength(in: storage, paragraph: paragraph))
        storage.deleteCharacters(in: marker)
        let content = NSRange(location: paragraph.location, length: paragraph.length - marker.length)
        let tagged = NSRange(location: content.location, length: min(content.length + 1, storage.length - content.location))
        let template = RichTextConverter.attributes(style: [], kind: kind)
        for key in [RichTextConverter.kindKey, .paragraphStyle] {
            if let value = template[key] { storage.addAttribute(key, value: value, range: tagged) } else { storage.removeAttribute(key, range: tagged) }
        }
        if kind != .plain {
            storage.insert(NSAttributedString(string: RichTextConverter.markerText(kind, number: 1)!, attributes: RichTextConverter.attributes(style: [], kind: kind, isMarker: true)), at: paragraph.location)
        }
    }

    /// Attribute-only change that registers undo and publishes like a typed edit.
    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let textView, let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isApplying, let replacement = replacementString, let storage = textView.textStorage else { return true }
        switch RichTextConverter.tokenEdit(range: range, replacement: replacement, in: storage) {
        case .allow:
            editMayCompleteToken = replacement.contains("}")
            return true
        case .reject:
            NSSound.beep()
            return false
        case .replace(let wider):
            textView.insertText(replacement, replacementRange: wider)
            return false
        }
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        adjustedSelection(from: old, to: new)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplying else { return }
        refreshState()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplying, let textView, let storage = textView.textStorage else { return }
        isApplying = true
        defer { isApplying = false }
        let selection = textView.selectedRange()
        let anchors = (anchor(selection.location), anchor(selection.upperBound))
        if editMayCompleteToken {
            RichTextConverter.chipTokens(in: storage, paragraphAt: RichTextConverter.paragraphIndex(containing: selection.location, in: storage.string))
            editMayCompleteToken = false
        }
        RichTextConverter.normalizeLists(storage)
        restoreSelection(anchors)
        let document = RichTextConverter.document(from: storage)
        hasCursorToken = Self.containsCursor(document)
        refreshState()
        onChange?(document)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, let storage = textView.textStorage,
              let paragraph = RichTextConverter.paragraphRanges(in: storage.string).last(where: { $0.location <= selection.location }) else { return false }
        let markerLength = RichTextConverter.markerLength(in: storage, paragraph: paragraph)
        guard markerLength > 0 else { return false }
        let kind = ParagraphKind(rawValue: storage.attribute(RichTextConverter.kindKey, at: paragraph.location, effectiveRange: nil) as? String ?? "") ?? .plain
        switch selector {
        case #selector(NSResponder.insertNewline(_:)) where paragraph.length == markerLength:
            clearList(paragraph)
        case #selector(NSResponder.insertNewline(_:)):
            let marker = NSAttributedString(string: "\n" + RichTextConverter.markerText(kind, number: 1)!, attributes: RichTextConverter.attributes(style: [], kind: kind, isMarker: true))
            textView.insertText(marker, replacementRange: selection)
        case #selector(NSResponder.deleteBackward(_:)) where selection.location == paragraph.location + markerLength:
            clearList(paragraph)
        default:
            return false
        }
        return true
    }

    /// Makes the selection step over tokens and list markers instead of into them.
    func adjustedSelection(from old: NSRange, to new: NSRange) -> NSRange {
        guard let storage = textView?.textStorage else { return new }
        var result = new
        storage.enumerateAttribute(RichTextConverter.tokenKey, in: NSRange(location: 0, length: storage.length)) { value, token, _ in
            guard value != nil else { return }
            if new.length == 0, new.location > token.location, new.location < token.upperBound {
                result.location = new.location >= old.location ? token.upperBound : token.location
            } else if new.length > 0, NSIntersectionRange(new, token).length > 0 {
                result = NSUnionRange(result, token)
            }
        }
        guard new.length == 0, let paragraph = RichTextConverter.paragraphRanges(in: storage.string).last(where: { $0.location <= new.location }) else { return result }
        let markerEnd = paragraph.location + RichTextConverter.markerLength(in: storage, paragraph: paragraph)
        if markerEnd > paragraph.location, new.location < markerEnd {
            let steppingLeft = old.location == markerEnd && new.location < old.location && paragraph.location > 0
            result.location = steppingLeft ? paragraph.location - 1 : markerEnd
        }
        return result
    }

    // MARK: State

    private func clearList(_ paragraph: NSRange) {
        guard let storage = textView?.textStorage else { return }
        let whole = NSRange(location: paragraph.location, length: min(paragraph.length + 1, storage.length - paragraph.location))
        edit(whole) { Self.setKind(.plain, on: paragraph, in: $0) }
        textView?.setSelectedRange(NSRange(location: paragraph.location, length: 0))
    }

    private func refreshState() {
        guard let textView, let storage = textView.textStorage else { return }
        sanitizeTypingAttributes()
        let selection = textView.selectedRange()
        activeStyles = selection.length > 0 && selection.location < storage.length
            ? RichTextConverter.style(of: storage.attributes(at: selection.location, effectiveRange: nil))
            : RichTextConverter.style(of: textView.typingAttributes)
        let paragraph = RichTextConverter.paragraphRanges(in: storage.string).last { $0.location <= selection.location }
        activeKind = paragraph.flatMap { $0.length > 0 ? storage.attribute(RichTextConverter.kindKey, at: $0.location, effectiveRange: nil) as? String : nil }
            .flatMap(ParagraphKind.init(rawValue:)) ?? .plain
    }

    /// Text typed next to a chip or a marker must not inherit it.
    private func sanitizeTypingAttributes() {
        guard let textView else { return }
        var typing = textView.typingAttributes
        guard typing[RichTextConverter.tokenKey] != nil || typing[RichTextConverter.listMarkerKey] != nil else { return }
        for key in [RichTextConverter.tokenKey, RichTextConverter.listMarkerKey, .backgroundColor] { typing.removeValue(forKey: key) }
        textView.typingAttributes = typing
    }

    /// A position as (paragraph, offset after the marker), which survives marker renumbering.
    private func anchor(_ location: Int) -> (paragraph: Int, offset: Int) {
        guard let storage = textView?.textStorage else { return (0, 0) }
        let ranges = RichTextConverter.paragraphRanges(in: storage.string)
        let index = ranges.lastIndex { $0.location <= location } ?? 0
        let start = ranges[index].location + RichTextConverter.markerLength(in: storage, paragraph: ranges[index])
        return (index, max(0, location - start))
    }

    private func restoreSelection(_ anchors: ((paragraph: Int, offset: Int), (paragraph: Int, offset: Int))) {
        guard let textView, let storage = textView.textStorage else { return }
        let ranges = RichTextConverter.paragraphRanges(in: storage.string)
        func location(_ anchor: (paragraph: Int, offset: Int)) -> Int {
            let range = ranges[min(anchor.paragraph, ranges.count - 1)]
            return min(range.location + RichTextConverter.markerLength(in: storage, paragraph: range) + anchor.offset, range.upperBound)
        }
        let start = location(anchors.0)
        textView.setSelectedRange(NSRange(location: start, length: max(0, location(anchors.1) - start)))
    }

    private static func containsCursor(_ document: Document) -> Bool {
        document.paragraphs.flatMap(\.runs).flatMap(\.spans).contains {
            if case .token(let token) = $0, token.kind == .cursor { true } else { false }
        }
    }
}

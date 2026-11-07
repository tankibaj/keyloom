import AppKit

/// Every item on the clipboard as type -> data. Held in memory only while a temporary write is in flight.
typealias PasteboardItems = [[String: Data]]

@MainActor
protocol PasteboardAccess: AnyObject, Sendable {
    var changeCount: Int { get }
    /// The current text, for `{clipboard}` rendering.
    func plainText() -> String?
    /// All items, or nil when they cannot be put back exactly (concealed/secret, promised or oversize data).
    func snapshot() -> PasteboardItems?
    /// Replaces the contents with plain + styled forms and returns the change count that is now ours.
    func write(plain: String, rtf: Data?) -> Int
    /// Puts `items` back only if the change count still equals `expected` at this instant; otherwise leaves the
    /// clipboard exactly as the other writer left it.
    func restore(_ items: PasteboardItems, ifChangeCount expected: Int) -> PasteboardRestore
}

enum PasteboardRestore: Equatable, Sendable {
    case restored, ownershipLost, failed
}

@MainActor
final class SystemPasteboard: PasteboardAccess {
    /// Larger clipboards are not copied into memory: the temporary write is refused instead.
    static let maxPreservedBytes = 8_000_000
    private static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    private let board = NSPasteboard.general

    var changeCount: Int { board.changeCount }

    func plainText() -> String? { board.string(forType: .string) }

    func snapshot() -> PasteboardItems? {
        var total = 0
        var items: PasteboardItems = []
        for item in board.pasteboardItems ?? [] {
            guard Self.concealedTypes.isDisjoint(with: item.types.map(\.rawValue)) else { return nil }
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= Self.maxPreservedBytes else { return nil }
                representations[type.rawValue] = data
            }
            items.append(representations)
        }
        return items
    }

    func write(plain: String, rtf: Data?) -> Int {
        board.clearContents()
        board.setString(plain, forType: .string)
        if let rtf { board.setData(rtf, forType: .rtf) }
        return board.changeCount
    }

    func restore(_ items: PasteboardItems, ifChangeCount expected: Int) -> PasteboardRestore {
        guard board.changeCount == expected else { return .ownershipLost }
        board.clearContents()
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        return items.isEmpty || board.writeObjects(restored) ? .restored : .failed
    }
}

extension RenderedSnippet {
    /// The styled form: every segment keeps its bold/italic/underline.
    func rtfData() -> Data? {
        let attributed = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 13)
        for segment in segments {
            var font = base
            if segment.style.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if segment.style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if segment.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attributed.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}

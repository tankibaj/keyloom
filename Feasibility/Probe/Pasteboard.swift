import AppKit

final class SystemPasteboard: PasteboardAccess {
    private let board = NSPasteboard.general

    func write(plain: String, rtf: Data?) {
        board.clearContents()
        board.setString(plain, forType: .string)
        if let rtf { board.setData(rtf, forType: .rtf) }
    }
}

extension RenderedSnippet {
    /// Styled payload: the plain text with the bold span applied.
    func rtfData() -> Data? {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        if let boldRange {
            attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: boldRange)
        }
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}

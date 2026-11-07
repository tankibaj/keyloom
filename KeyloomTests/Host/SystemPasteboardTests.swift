import AppKit
import XCTest
@testable import Keyloom

/// A private named pasteboard, so the user's real clipboard is never touched.
@MainActor
final class SystemPasteboardTests: XCTestCase {
    func testTheBorrowedClipboardIsTransientButAnExplicitCopyIsNot() {
        let type = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let borrowed = NSPasteboard(name: NSPasteboard.Name("keyloom-test-\(UUID().uuidString)"))
        let copied = NSPasteboard(name: NSPasteboard.Name("keyloom-test-\(UUID().uuidString)"))
        addTeardownBlock { borrowed.releaseGlobally(); copied.releaseGlobally() }
        _ = SystemPasteboard(board: borrowed).write(plain: "borrowed", rtf: nil, transient: true)
        _ = SystemPasteboard(board: copied).write(plain: "copied", rtf: nil, transient: false)
        XCTAssertNotNil(borrowed.data(forType: type))
        XCTAssertNil(copied.data(forType: type))
    }

    func testOurOwnLeftOverTransientWriteDoesNotBlockTheNextSnapshotButSomeoneElsesDoes() {
        let native = NSPasteboard(name: NSPasteboard.Name("keyloom-test-\(UUID().uuidString)"))
        addTeardownBlock { native.releaseGlobally() }
        let board = SystemPasteboard(board: native)
        _ = board.write(plain: "ours", rtf: nil, transient: true)
        XCTAssertNotNil(board.snapshot(), "A paste that never confirmed leaves our write in place")
        native.clearContents()
        native.setString("secret", forType: .string)
        native.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        XCTAssertNil(board.snapshot(), "Another app's transient item is never copied")
    }
}

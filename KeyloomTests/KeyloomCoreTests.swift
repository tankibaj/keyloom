import XCTest

/// Swift side of the C boundary; the Rust side lives in Core/tests/c_abi.rs.
final class KeyloomCoreTests: XCTestCase {
    func testRustLibraryIsLinkedAndReportsAbiVersion() {
        XCTAssertEqual(KeyloomCore.abiVersion, 1)
    }
}

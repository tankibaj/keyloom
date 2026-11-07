import XCTest
@testable import Keyloom

@MainActor
final class AppModelSingleFlightTests: LibraryUITestCase {
    /// The environment and the library window both ask for the library at launch; it must open once.
    func testConcurrentOpensShareOneDatabaseOpen() async throws {
        var opened = 0
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] directory in
            opened += 1
            return try await openLibrary(at: directory)
        })
        async let first: Void = model.open()
        async let second: Void = model.open()
        _ = await (first, second)
        XCTAssertEqual(opened, 1)
        XCTAssertNotNil(model.library)
    }

    func testAFailedOpenCanBeRetried() async throws {
        var attempts = 0
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] directory in
            attempts += 1
            if attempts == 1 { throw StoreError.closed }
            return try await openLibrary(at: directory)
        })
        await model.open()
        XCTAssertNil(model.library)
        await model.open()
        XCTAssertNotNil(model.library)
        XCTAssertEqual(attempts, 2)
    }
}

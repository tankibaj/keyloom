import Foundation

/// Where the library lives. `--keyloom-data-dir <path>` overrides it so UI tests and reviewers can seed a
/// synthetic library; under XCTest the real library is never touched.
enum DataLocation {
    static let launchArgument = "--keyloom-data-dir"

    static func resolve(arguments: [String] = CommandLine.arguments,
                        isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) -> URL {
        if let flag = arguments.firstIndex(of: launchArgument), arguments.indices.contains(flag + 1) {
            return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }
        if isRunningTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent("keyloom-host-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Keyloom", isDirectory: true)
    }

    static func databaseURL(in directory: URL) -> URL { directory.appendingPathComponent("keyloom.sqlite") }
    static func snapshotDirectory(in directory: URL) -> URL { directory.appendingPathComponent("Snapshots", isDirectory: true) }

    /// Opens (creating the folder first) the library in `directory`. `backupDirectory` receives the store's
    /// automatic pre-migration copies.
    static func openLibrary(in directory: URL, backupDirectory: URL) async throws -> SnippetLibrary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await SnippetLibrary(url: databaseURL(in: directory), backupDirectory: backupDirectory)
    }
}

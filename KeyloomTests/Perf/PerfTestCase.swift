import XCTest
@testable import Keyloom

/// Base for in-process performance tests over the synthetic 1,000-snippet library.
///
/// The default suite stays deterministic: it asserts operation counts and correctness and takes only a few
/// timing samples, which it reports but never asserts. `KEYLOOM_PERF=1` takes `perfSampleCount` samples and
/// asserts each p95 against its budget (run it on an idle Mac, Release configuration; with `xcodebuild` pass it
/// as `TEST_RUNNER_KEYLOOM_PERF=1`).
class PerfTestCase: StoreTestCase {
    static let perfEnabled = ProcessInfo.processInfo.environment["KEYLOOM_PERF"] == "1"
    static let perfSampleCount = 200

    var sampleCount: Int { Self.perfEnabled ? Self.perfSampleCount : 3 }

    /// A fresh copy of the synthetic library, written through the real store, opened through the real actor.
    func openFixtureLibrary() async throws -> (library: SnippetLibrary, directory: URL) {
        let directory = try makeDirectory().appendingPathComponent("fixture")
        let database = try await SyntheticLibrary.write(to: directory)
        let library = try await SnippetLibrary(url: database, backupDirectory: directory.appendingPathComponent(SyntheticLibrary.backupsName))
        return (library, directory)
    }

    func renderEnvironment() -> RenderEnvironment {
        RenderEnvironment(date: Date(timeIntervalSince1970: 1_768_485_909), timeZone: TimeZone(identifier: "UTC")!,
                          locale: Locale(identifier: "en_US_POSIX"), makeUUID: { UUID() }, clipboardText: { "clip" })
    }

    /// Wall-clock milliseconds of each run of `body`, after one untimed warm-up run.
    func samples(_ count: Int, _ body: (Int) async throws -> Void) async rethrows -> [Double] {
        try await body(0)
        var milliseconds: [Double] = []
        let clock = ContinuousClock()
        for index in 0..<count {
            let elapsed = try await clock.measure { try await body(index) }
            milliseconds.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return milliseconds
    }

    /// Nearest-rank percentile.
    static func percentile(_ fraction: Double, of values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)]
    }

    /// Reports `PERF <name> n= p50= p95= budget=` (test log and attachment). Asserts p95 within `budgetMilliseconds`
    /// only under `KEYLOOM_PERF=1`.
    func report(_ name: String, _ milliseconds: [Double], budgetMilliseconds: Double? = nil,
                file: StaticString = #filePath, line: UInt = #line) {
        let p50 = Self.percentile(0.5, of: milliseconds)
        let p95 = Self.percentile(0.95, of: milliseconds)
        let budget = budgetMilliseconds.map { String(format: "%.0fms", $0) } ?? "none"
        let text = String(format: "PERF %@ n=%d p50=%.3fms p95=%.3fms budget=%@ asserted=%@", name, milliseconds.count, p50, p95,
                          budget, Self.perfEnabled && budgetMilliseconds != nil ? "yes" : "no")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if Self.perfEnabled, let budgetMilliseconds {
            XCTAssertLessThan(p95, budgetMilliseconds, "\(name) p95 over budget", file: file, line: line)
        }
    }
}

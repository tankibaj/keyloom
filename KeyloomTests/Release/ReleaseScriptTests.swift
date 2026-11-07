import XCTest

/// Drives scripts/release (release.sh and lib.zsh) as a subprocess. Only the credential-free paths run here:
/// argument parsing, the env check, refusal to build, vtool parsing, verdicts and evidence rendering.
/// A real archive, signing and notarization are never started.
final class ReleaseScriptTests: XCTestCase {
    private struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    private let identity = "SENTINEL-IDENTITY-VALUE"
    private let profile = "SENTINEL-PROFILE-VALUE"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var libPath: String { repoRoot.appendingPathComponent("scripts/release/lib.zsh").path }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyloom-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func run(_ arguments: [String], environment: [String: String] = [:], in directory: URL) throws -> Result {
        let outURL = directory.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        let errURL = directory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "HOME": directory.appendingPathComponent("home").path,
        ].merging(environment) { $1 }
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try outHandle.close()
        try errHandle.close()
        return Result(status: process.terminationStatus,
                      out: try String(contentsOf: outURL, encoding: .utf8),
                      err: try String(contentsOf: errURL, encoding: .utf8))
    }

    /// A throwaway git repo holding a copy of scripts/release, so the script's ROOT is the temp dir.
    private func makeRepo(dirty: Bool = false) throws -> URL {
        let repo = try makeTempDir()
        let target = repo.appendingPathComponent("scripts/release")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("scripts/release"), to: target)
        try "tracked\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let git = "git init -q . && git add -A && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init"
        let result = try run(["-c", git], in: repo)
        XCTAssertEqual(result.status, 0, result.err)
        if dirty {
            try "changed\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        }
        return repo
    }

    private func script(in repo: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> Result {
        try run(["scripts/release/release.sh"] + arguments, environment: environment, in: repo)
    }

    /// Runs shell code with lib.zsh sourced from this repo.
    private func lib(_ code: String, environment: [String: String] = [:], in directory: URL? = nil) throws -> Result {
        try run(["-c", "source \"$1\"; \(code)", "zsh", libPath], environment: environment, in: directory ?? makeTempDir())
    }

    private var allEnv: [String: String] {
        ["KEYLOOM_SIGN_IDENTITY": identity, "KEYLOOM_NOTARY_PROFILE": profile]
    }

    private func trimmed(_ result: Result) -> String { result.out.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: argument parsing

    func testHelpExitsZeroAndUnknownOptionIsUsageError() throws {
        let repo = try makeRepo()
        let help = try script(in: repo, ["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.out.contains("--dry-run"))

        let bad = try script(in: repo, ["--bogus"])
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.err.contains("--bogus"), bad.err)
    }

    func testConflictingModesAndBadSyncStateAreUsageErrors() throws {
        let repo = try makeRepo()
        XCTAssertEqual(try script(in: repo, ["--dry-run", "--check-env"]).status, 2)
        XCTAssertEqual(try script(in: repo, ["--dry-run", "--sync-state", "on; rm -rf /"]).status, 2)
        XCTAssertEqual(try script(in: repo, ["--dry-run", "--sync-state"]).status, 2)
    }

    // MARK: env check

    func testCheckEnvListsMissingVariablesByNameOnly() throws {
        let repo = try makeRepo()
        let result = try script(in: repo, ["--check-env"], environment: ["KEYLOOM_SIGN_IDENTITY": identity])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.out.contains("KEYLOOM_NOTARY_PROFILE: MISSING"), result.out)
        XCTAssertFalse((result.out + result.err).contains(identity))
    }

    func testCheckEnvPassesWhenAllSetAndNeverPrintsValues() throws {
        let repo = try makeRepo()
        let result = try script(in: repo, ["--check-env"], environment: allEnv)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("KEYLOOM_SIGN_IDENTITY: set"), result.out)
        XCTAssertFalse((result.out + result.err).contains(identity))
        XCTAssertFalse((result.out + result.err).contains(profile))
    }

    func testEmptyVariableCountsAsMissing() throws {
        let missing = try lib("KEYLOOM_SIGN_IDENTITY=''; KEYLOOM_NOTARY_PROFILE=x; release_missing_env")
        XCTAssertEqual(trimmed(missing), "KEYLOOM_SIGN_IDENTITY")
    }

    // MARK: refusal before any build

    func testFullRunRefusesWithoutEnvAndBuildsNothing() throws {
        let repo = try makeRepo()
        let result = try script(in: repo, [])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue((result.out + result.err).contains("KEYLOOM_SIGN_IDENTITY"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("dist").path))
    }

    func testFullRunRefusesDirtyTrackedTreeAndNeverPrintsValues() throws {
        let repo = try makeRepo(dirty: true)
        let result = try script(in: repo, [], environment: allEnv)
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.err.contains("clean"), result.err)
        XCTAssertFalse((result.out + result.err).contains(identity))
        XCTAssertFalse((result.out + result.err).contains(profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("dist").path))
    }

    func testDryRunAlsoRefusesDirtyTreeButNeedsNoCredentials() throws {
        let dirty = try script(in: try makeRepo(dirty: true), ["--dry-run"])
        XCTAssertEqual(dirty.status, 2)
        XCTAssertTrue(dirty.err.contains("clean"), dirty.err)

        // Clean tree, no env: it passes the env and tree gates and only then fails on the missing Xcode project.
        let clean = try script(in: try makeRepo(), ["--dry-run"])
        XCTAssertFalse(clean.err.contains("KEYLOOM_SIGN_IDENTITY"), clean.err)
        XCTAssertFalse(clean.err.contains("clean"), clean.err)
    }

    func testTreeCheckIgnoresUntrackedFilesAndRejectsNonRepos() throws {
        let repo = try makeRepo()
        try "x".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try lib("release_tree_is_clean \"$PWD\"").status, 1, "a fresh temp dir is not a repo")
        let inRepo = try lib("release_tree_is_clean \"$PWD\"", in: repo)
        XCTAssertEqual(inRepo.status, 0, inRepo.err)
    }

    // MARK: pure helpers

    func testParseMinosReadsVtoolOutput() throws {
        let sample = "Load command 9\n      cmd LC_BUILD_VERSION\n  platform MACOS\n    minos 26.0\n      sdk 27.0\n"
        let parsed = try lib("release_parse_minos <<'EOF'\n\(sample)EOF\n")
        XCTAssertEqual(trimmed(parsed), "26.0")
        XCTAssertEqual(parsed.status, 0)
        let none = try lib("release_parse_minos <<'EOF'\nnothing here\nEOF\n")
        XCTAssertNotEqual(none.status, 0)
    }

    func testOverallVerdictFailBeatsNotVerifiedBeatsPass() throws {
        let cases: [(String, String)] = [
            ("PASS PASS", "PASS"),
            ("PASS 'NOT VERIFIED'", "NOT VERIFIED"),
            ("'NOT VERIFIED' FAIL PASS", "FAIL"),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(trimmed(try lib("release_overall_verdict \(arguments)")), expected, arguments)
        }
    }

    // MARK: evidence

    private let evidenceVars = """
        EV_MODE=dry-run EV_GIT_SHA=abc1234 EV_MACOS=27.2 EV_MACOS_BUILD=27C1 EV_XCODE='Xcode 27.0' EV_SDK=macosx27.0 \
        EV_HW_MODEL=Mac16,1 EV_CHIP='Apple M4' EV_ARCH=arm64 EV_MINOS=26.0 EV_BUNDLE_MIN=26.0 \
        EV_VERSION=0.0.1 EV_BUILD=1 EV_SYNC_STATE=off-test EV_BUILD_STATUS=PASS \
        EV_SIGN_STATUS='NOT VERIFIED' EV_NOTARY_STATUS='NOT VERIFIED' EV_STAPLE_STATUS='NOT VERIFIED' \
        EV_GATEKEEPER_STATUS='NOT VERIFIED'
        """

    func testDryRunEvidenceRecordsFactsAndIsNotVerified() throws {
        let result = try lib("\(evidenceVars) release_render_evidence")
        XCTAssertEqual(result.status, 0, result.err)
        for expected in ["abc1234", "27.2", "Xcode 27.0", "macosx27.0", "Mac16,1", "Apple M4", "arm64", "minos: 26.0",
                         "0.0.1", "off-test", "Signing: NOT VERIFIED", "Notarization: NOT VERIFIED",
                         "GitHub release: NOT VERIFIED", "Overall: NOT VERIFIED"] {
            XCTAssertTrue(result.out.contains(expected), "missing \(expected) in\n\(result.out)")
        }
    }

    func testEvidenceRedactsHomeFolderAndNeverIncludesCredentialValues() throws {
        let home = "/Users/someone-private"
        let result = try lib("\(evidenceVars) EV_XCODE='tool at \(home)/x' release_render_evidence",
                             environment: ["HOME": home, "KEYLOOM_SIGN_IDENTITY": identity, "KEYLOOM_NOTARY_PROFILE": profile])
        XCTAssertFalse(result.out.contains(home), result.out)
        XCTAssertTrue(result.out.contains("~/x"), result.out)
        XCTAssertFalse(result.out.contains(identity))
        XCTAssertFalse(result.out.contains(profile))
    }

    func testFullRunEvidenceRecordsArtifactChecksumAndKeepsPublicationSeparate() throws {
        let result = try lib("""
            \(evidenceVars) EV_MODE=release EV_SIGN_STATUS=PASS EV_NOTARY_STATUS=PASS EV_STAPLE_STATUS=PASS \
            EV_GATEKEEPER_STATUS=PASS EV_ARTIFACT=Keyloom-0.0.1-arm64.zip EV_SHA256=deadbeef release_render_evidence
            """)
        XCTAssertTrue(result.out.contains("Keyloom-0.0.1-arm64.zip"), result.out)
        XCTAssertTrue(result.out.contains("deadbeef"), result.out)
        XCTAssertTrue(result.out.contains("Notarization: PASS"), result.out)
        XCTAssertTrue(result.out.contains("Overall: PASS"), result.out)
        XCTAssertTrue(result.out.contains("GitHub release: NOT VERIFIED"), "publication is a manual, separate item")
    }

    /// The shipped binary must not carry the test-only symbols that `@testable` needs; tests keep testability in
    /// their own build configuration.
    func testTheArchiveStepTurnsTestabilityOff() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("scripts/release/release.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "xcodebuild archive"))
        let archiveCommand = script[start.lowerBound...].prefix { $0 != ">" }
        XCTAssertTrue(archiveCommand.contains("ENABLE_TESTABILITY=NO"), String(archiveCommand))
    }
}

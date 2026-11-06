# Native accessibility, performance and release
**Status:** Ready | **Owner:** harnex | **Updated:** 2026-11-06 23:24

repo: /Users/naim/Repos/keyloom
depends: WP3–6 integrated
parallel: no
Owned files (all proposed): KeyloomUITests/Release/, Profiling/, Distribution/, docs/release/. Existing owners resolve issues on their surfaces. Existing tests: KeyloomTests/AppIdentityTests asserts the 26.0 baseline and stays green.

## Changes in order
- [ ] A (120–250): release-mode profile harness/fixture and independent native UI journeys. Offline with AI off on physical Macs running macOS 26 and 27; light/dark snapshots, Auto switches, menu bar, panels, editor, every Settings tab, keyboard-only/VoiceOver, Reduce Motion/Transparency, Increase Contrast and 27 enhanced borders.
- [ ] B (150–300): seed 1,000 synthetic snippets (~1 MiB); record hardware/OS/build, sync state, sample counts, UI closed. Physical footprint ≤50 MiB; mean CPU <0.1% over five quiet minutes; p95 warm picker <150 ms and visible no-input replacement <50 ms. Measure end-to-visible effect with AI off and enabled-but-unused, then active AI and back to idle.
- [ ] C (100–220): arm64 Release with deployment target 26.0 (binary minos and bundle minimum already confirmed; re-check on the artifact); verify Developer ID signature, notarization, stapling and Gatekeeper on a clean install. Confirm a redistribution license with Naim before publishing; public release only with explicit authorization, remote and signed artifact.

## Done checks
- [ ] After the FULL Release suites (`-scheme Keyloom` and `-scheme KeyloomProbe`, `xcodebuild … test`), the validator records native UI and synthetic-data evidence and a secret scan (no dependency audit: no packages). Reviewer checks the whole diff, then the native UI reviewer inspects every changed screen on a passing build. External results recorded as observed; missing qualifiers stay pending. For a public release verify downloaded artifact checksum, signature, launch and the actual GitHub Releases URL.
- [ ] Readiness, notarization and publication are separate evidence items. Independent reviewer/validator own verdicts. Missing real destinations, second hardware, managed restrictions, macOS 26 hardware, external signing, live CloudKit proof or release authorization appear in the final report.

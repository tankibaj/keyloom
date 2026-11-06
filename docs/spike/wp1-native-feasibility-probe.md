# WP1 native feasibility probe (B1, B2, C1, C2, D)
**Status:** In Progress | **Owner:** harnex | **Updated:** 2026-11-06

Evidence log for `docs/wp/wp1-native-feasibility.md`. Probe code never ships: it lives in `Feasibility/`, links only into the `KeyloomProbe` and `KeyloomProbeTests` targets, and the `Keyloom` target/scheme does not depend on it.

**Architecture: pure Swift (approved by Naim).** The earlier Rust static library, C interface and Cargo workspace are gone; the matcher and renderer are Swift (`Feasibility/Probe/Recognizer.swift`). Snippet-App-Plan.md architecture was amended to match. Swift 5 language mode on probe targets only (warnings as errors); shipping target is Swift 6 (minimum 26.0 for both pure Swift).

**Baseline verified on macOS 27.2:** Independent clean Release arm64 build with SDK 27: scheme `Keyloom` 2/2 (KeyloomTests/AppIdentityTests), scheme `KeyloomProbe` 44/44 (Feasibility/ProbeTests: Recognizer 11, Engine 27, CloudProbe 6), 0 failures. Swift-only snapshot exported to `.git/keyloom-swift-baseline.tgz`, SHA256 `f768172af7d3e1e2c72df85e4fa8ea7a123608b18998b31bb6587885f92944f3`. Those tests use fakes for the OS boundaries, so they prove decision logic and Swift matcher/renderer behavior only.

**Verdict: NOT VERIFIED for live evidence.** Everything marked NOT VERIFIED needs a human at the keyboard with granted permissions, or a CloudKit-provisioned signing identity. No simulated destination counts as a pass, no live keyboard run and no CloudKit operation was done.

## What exists
| Area | Where | Notes |
|---|---|---|
| Fixture recognizer and UTF-16 template renderer | `Feasibility/Probe/Recognizer.swift` | Bounded 32-unit buffer, immediate match, `;kl` `;grüß` `;hi`, composed/decomposed ü, UTF-16 caret position |
| Engine (all fail-closed decisions) | `Feasibility/Probe/Engine.swift` | OS boundaries are protocols; typed text never stored or logged, only counters; delivery never writes clipboard (user Copy only) |
| OS input hook | `Probe/EventTap.swift` | Listen-only session `CGEventTap`; origin classified physical (no source pid), synthetic (other pid), own (probe marker/pid, dropped) |
| AX target, caret, replace | `Probe/Destination.swift` | AX plain: focus re-read per call, plain text replace only, bound re-validation before each mutation; allow-list TextEdit/Safari/VS Code, AXTextArea/AXTextField only |
| User Copy (fallback) | `Probe/Pasteboard.swift`, engine `copyFallback` | Explicit Copy button only; writes plain text + RTF to pasteboard, never during delivery |
| Opt-in CloudKit | `Probe/CloudProbe.swift` | No container lookup at launch; blocked unless the build's entitlements contain the supplied container |
| UI | `Probe/ProbeApp.swift` | Permission status (Accessibility, Input Monitoring), request button, Armed toggle, delivery mode (AX plain only), counters, outcomes, Copy buttons |
| Tests | `Feasibility/ProbeTests/{Recognizer,Engine,CloudProbe}Tests.swift`, `KeyloomTests/AppIdentityTests.swift` | Baseline 44 probe tests (11 Recognizer, 27 Engine, 6 CloudProbe), 2 app tests; A0 safety tests 4 new (target 59 probe after A0) |

Fail-closed rules (each has an engine test): not armed; secure event input; any non-layout input source (IME) ; secure field; app not allow-listed; role not text area/field; text unreadable; no `KL-FIXTURE-v1` marker (such text never reaches the matcher); unknown focus; range selection at trigger; keyword not found before the caret; prompt then focus/text/selection changed or app not re-activated (nothing written); cancel (nothing written). Copy fallback happens only on a button press. Synthetic input is ignored unless the self-test toggle is on and is counted separately, so it cannot be mistaken for physical evidence.

## Commands (run from the checkout root; Xcode with SDK 27 only, no other toolchain)
```
xcodebuild -project Keyloom.xcodeproj -scheme Keyloom -configuration Release -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Keyloom.xcodeproj -scheme KeyloomProbe -configuration Release -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Keyloom.xcodeproj -scheme KeyloomProbe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .derived build
open .derived/Build/Products/Release/KeyloomProbe.app
```
Shipping isolation check (expect 0): `nm .derived/Build/Products/Release/Keyloom.app/Contents/MacOS/Keyloom | grep -ci probe` after building the `Keyloom` scheme into the same derived data path.

Ad-hoc signing changes the code identity on every build: after rebuilding, remove and re-add KeyloomProbe in System Settings > Privacy & Security (Accessibility, Input Monitoring).

## Live run (human)
Synthetic text only. Fixture document: `KL-FIXTURE-v1⏎START  END` (two spaces). Use **Copy fixture document**, open a NEW document in TextEdit, Safari textarea, or VS Code, paste, then press Left 4 times (caret between the spaces). Arm the probe and return to the document.

1. Open the probe. Permissions rows must show Accessibility and Input Monitoring granted. **Arm** must refuse until both are granted. (Post Events is not required for AX plain text delivery.)
2. Arm. Type `;kl` on the physical keyboard in the fixture document.
   - Expected (AX plain text, default delivery): `KL-FIXTURE-v1⏎START Hallo 👩🏽‍💻 Keyloom! END`, 46 UTF-16 units, caret at UTF-16 offset 41 (before `!`). All text is plain (no markup). Outcome line shows `replaced(... verified: true ...)`, report shows `Physical input evidence: yes`.
3. `;hi` then **Insert** with the default recipient: `START Hi Alex Fixture! END`, caret 35. **Cancel**: text stays `START ;hi END`, outcome `cancelled`. Click elsewhere in the destination or switch field, then **Insert**: outcome `aborted(destinationChanged)`, text unchanged. **Copy** button (fallback only) puts the text on the clipboard; manually paste with Cmd+V.
4. `;grüß` on a German layout with composed ü or dead-key ¨+u: `START Grüße 😀 END`, caret 25.
5. Rich mode delivery: The UI shows a "Rich (field-bound writer)" mode, but it fails closed (no field-bound writer exists for AX destinations). Select it, type `;kl`: outcome `failedClosed(richUnsupported)`. Copy button works; manually paste.
6. Secure input and IME: Focus a password field or turn on Secure Keyboard Entry in Terminal: typing `;kl` yields no outcome, `suppressedSecure` rises. Switch to an IME (e.g. Japanese Hiragana): `suppressedComposing` rises, nothing replaced. A document without the `KL-FIXTURE-v1` marker: nothing happens.
7. Permissions: Revoke Accessibility while armed: probe disarms within ~1 s ("Permission revoked"), destination untouched.
8. Report: **Copy report** and paste the outcome lines (no typed text inside) into the table below.

VS Code: set `"editor.accessibilitySupport": "on"`. Monaco may still not expose AXValue/selection; if the result is `failedClosed(unreadableValue)` or `appNotAllowed`, that is the recorded characterization for that app. Copy button (fallback) and manual paste is still available.

## Matrix (fill from live runs)
| Destination | B1 hook+perm | B2 keys/IME/secure | C1 prompt/cancel/change | C2 rich/plain/caret/clipboard | Result |
|---|---|---|---|---|---|
| TextEdit rich | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED |
| TextEdit plain | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED |
| Safari textarea/contenteditable (local fixture) | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED |
| VS Code | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED |

## D: CloudKit and footprint
- CloudKit live probe: **NOT VERIFIED (pending by Naim's instruction; no request was made).** Needs a signed build with a CloudKit-capable profile for a test container you own (template: `Feasibility/CloudKit.entitlements.example`, deliberately unreferenced) and the container id typed into the probe. The probe saves one `kl-probe-<UUID>` record of type `KeyloomProbe` in the private database, fetches it, deletes it, reads back absence, and always attempts delete after a save. Without entitlements it reports `NOT VERIFIED: ... not provisioned` and creates no container.
- Footprint/CPU: NOT MEASURED. With the Release `Keyloom` app idle and UI closed, `footprint <pid>` and `top -pid <pid> -l 300 -s 1 -stats cpu`; record machine, OS 27.x, SDK 27, signing mode, without identifiers. The `Keyloom` target is the scaffold, so this is only a baseline.

## Known limits (honest)
- IME detection is by input source type, not real marked text; any input method fails closed.
- AX range units can differ from UTF-16 in some apps (grapheme clusters); the emoji-before-caret fixture exists to expose that. Not yet observed.
- Rich field-bound writer mode is not implemented: AX Accessibility API has no safe way to deliver styled text to a specific field (synthetic Cmd+V cannot be bound to the focused field at the moment of paste). Rich mode fails closed; user Copy button and manual paste is the fallback.
- Event tap sees keys before the destination applies them; the engine waits up to 0.5 s for the keyword to appear before judging.
- Fake-backed engine tests prove decision logic only. The recognizer tests prove the Swift matcher/renderer only.
- Probe tests compile the probe sources directly (not app-hosted). Swift 5 language mode for probe targets only; warnings remain errors.

## Decision
None yet: WP2 stays blocked until the matrix and D are filled in or Naim decides otherwise.

# Keyloom

A macOS menu-bar text expander. Type a keyword such as `::sig` in any app and Keyloom replaces it with a snippet: rich text, dates, clipboard, prompted arguments and a cursor position. Snippets stay on your Mac; iCloud sync is optional and off by default.

- **Requires** macOS 26 or later, Apple Silicon. Swift 6, no third-party dependencies.
- **One permission:** Accessibility. No Input Monitoring, no Post Events.
- **Bundle id** `com.thenaim.keyloom`.

## Screenshots

<p align="center">
  <img src="docs/images/library-light.png" alt="Keyloom library window, light" width="49%">
  <img src="docs/images/library-dark.png" alt="Keyloom library window, dark" width="49%">
</p>

The library window: tags and status in the sidebar, snippet rows with keyword chips and one-line previews, and an editor with token pills, a live "Expands to" preview, keyword-conflict check and usage line. A menu-bar popover gives quick insert, pause and a permission banner; Settings has General, Expansion, Sync and Assistance.

## Snippets

Templates support these tokens:

| Token | Result |
|---|---|
| `{date}` `{time}` (with an optional `format`) | current date / time |
| `{uuid}` | a fresh UUID |
| `{clipboard}` | current clipboard text, read only when a snippet uses it |
| `{argument name="…" default="…"}` | asked for in a prompt before inserting (can offer choices) |
| `{cursor}` | where the caret lands after insertion |

Bold, italic, underline and lists are kept where the destination takes styled text. A keyword matches the moment its last character is typed (no delimiter). The picker (default `⌃⌥Space`) and the menu bar insert a snippet without typing its keyword. Raycast snippets can be imported; snippets export to a native format. Daily snapshots back up the library.

## Install and develop

```sh
scripts/install.sh      # build Release and install to /Applications
scripts/build.sh        # build only, prints the .app path
```

After the first install, grant **Accessibility** in System Settings → Privacy & Security (the Expansion tab has the button). The install script signs the ad-hoc build with a designated requirement on the bundle id, so the grant survives rebuilds.

Unit tests:

```sh
xcodebuild test -project Keyloom.xcodeproj -scheme Keyloom -destination 'platform=macOS' \
  -derivedDataPath /tmp/keyloom-dd ENABLE_TESTABILITY=YES SWIFT_OPTIMIZATION_LEVEL=-Onone \
  -only-testing:KeyloomTests
```

UI journeys run from the `KeyloomUITests` scheme against inert OS boundaries (no tap, hotkey or permission needed). `scripts/release/release.sh --help` documents the Developer ID release; `scripts/profile/profile.sh --help` the idle profile.

## Architecture

### Layers

```mermaid
flowchart TB
    subgraph UI["UI (SwiftUI)"]
        direction LR
        Library[Library window + editor]
        Menu[Menu bar + picker]
        Settings[Settings]
    end
    Env[AppEnvironment<br/>composition root, live or UI-test dependencies]
    subgraph Host["Host: typing pipeline"]
        direction LR
        Tap[EventTap] --> IH[InputHost] --> Ctl[InputHostController]
    end
    Lib[SnippetLibrary actor<br/>indexes and in-memory snapshot]
    Store[(SnippetStore<br/>SQLite, one actor)]
    Core[Core: Document, TokenParser,<br/>TemplateRenderer, KeywordMatcher, Search]
    Sync[Sync: CKSyncEngine]
    Back[Backups, Portability]
    Assist[Assistance: on-device model]

    UI --> Env
    Env --> Host
    Env --> Lib
    Host --> Lib
    Lib --> Store
    Lib --> Core
    Sync --> Store
    Back --> Lib
    Assist -. explicit request only .-> UI
```

`SnippetLibrary` is the only app-facing data API. After every committed write it reloads, rebuilds the keyword and search indexes and swaps the keyword index into `KeywordIndexStore`. The matcher reads that store directly, so typing never waits on the database.

### From keystroke to expansion

```mermaid
sequenceDiagram
    participant U as You
    participant T as EventTap
    participant H as InputHost
    participant M as KeywordMatcher
    participant C as InputHostController
    participant X as ExpansionCoordinator
    participant A as App you type in

    U->>T: key down
    T->>H: origin + lazy key text
    H->>H: privacy gates (paused, secure input, IME, excluded app, own events)
    H->>M: feed(scalars)
    M-->>H: keyword match
    H->>C: onMatch (callback returns at once)
    C->>C: suspend host, keys meanwhile are dropped and counted
    C->>X: handle(match)
    X->>A: bind keyword to the focused field, re-verify before writing
    X->>X: render snippet, prompt for arguments if needed
    X->>A: replace keyword (see routes below)
    C->>C: resume host, record usage in the background
```

### Insertion routes

```mermaid
flowchart TD
    Match([keyword matched]) --> Bind{Accessibility can bind<br/>the focused field?}
    Bind -- yes, text field --> AX[Replace through Accessibility<br/>read back and verify]
    AX -- confirmed --> Done([inserted])
    AX -- ignored or failed,<br/>field unchanged on 2 reads --> Blind
    Bind -- no focus, unreadable,<br/>web area or custom view --> Blind
    Bind -- secure field, excluded app,<br/>keyword not before caret --> Refuse([refused, Copy offered])
    Blind{Typing over allowed?<br/>switch on, not Finder,<br/>not a list or menu,<br/>nothing typed since match} -- yes --> Type[Delete x keyword, paste<br/>posted to the frontmost process,<br/>clipboard borrowed and restored]
    Blind -- no --> Refuse
    Type --> Done
```

The Accessibility route verifies every step and fails closed. The typing route cannot read the field back, so it is bounded by guards instead and reports its insertions as unverified.

## Privacy

- Keys are matched in memory over a buffer capped at the longest keyword. Typed text, snippet text and clipboard contents are never stored or logged; logs and counters hold outcome names only.
- No keys are read while secure input is on, while an input method is composing, in excluded apps, or in Keyloom itself.
- The clipboard is touched only for the typing route and the explicit rich-paste route, tagged transient so clipboard managers skip it, and given back only while it is still Keyloom's.
- Sync, when enabled, uses your private iCloud database. Writing assistance runs on-device and only on text you select.

## Status

iCloud sync needs a build signed with a CloudKit entitlement and a provisioned container; builds made with `scripts/install.sh` report "not signed for iCloud". The typing route is covered by unit tests with fakes; behavior in particular apps (browsers, Electron, terminals) has to be checked by hand.

## App icon

The icon is an Icon Composer file, `Icon/AppIcon.icon` ("Weave", all looks: default, dark, tinted, clear). `tools/make_icon.sh` compiles it with `actool` into `Resources/` (review only; the Xcode build bundles it), and `tools/icon_review.sh` renders a contact sheet of every look. The menu-bar glyph is a template image with a badge variant when Accessibility is missing.

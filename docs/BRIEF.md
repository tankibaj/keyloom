# Keyloom UI brief
**Status:** In Progress | **Owner:** harnex | **Updated:** 2026-11-07 02:00

Design record for WP4 (native library, editor, picker, Settings). Views follow it; the HTML prototype is reference only.

## Archetype and feeling
- mac-design archetype: **document-style productivity utility** (Notes / Mail / Shortcuts family): one main window, sidebar + list + detail, plus later a menu-bar extra, a floating picker panel and a Settings window.
- Feeling: calm, quick, trustworthy. The app handles text the user types everywhere, so it never surprises: nothing is saved or deleted without a visible, reversible step.
- System everything: `NavigationSplitView`, toolbar, `.searchable`, SF Symbols, semantic colors and Dynamic Type fonts. Liquid Glass comes from the system in sidebar, toolbar and controls; no custom chrome, no custom materials. The editing surface (the body text view) is a flat, opaque `textBackgroundColor` surface so text stays legible under Reduce Transparency and Increase Contrast.
- Appearance follows the system (Light, Dark, Auto); the app sets nothing itself until Settings adds an override.

## Information architecture
- Window (single, `Window` scene "Keyloom"):
  - Sidebar: Library (All Snippets, Recently Used, Pinned), Tags (one row per tag, with counts), Recently Deleted.
  - Content: lazy list of rows: icon (emoji or SF Symbol), name, keyword (monospaced, secondary), pin glyph.
  - Detail: editor for the selected snippet or a new draft: name, icon, keyword, tags, expansion toggle, formatted body with toolbar and Insert Placeholder, live preview and Try Expansion.
- Toolbar: New Snippet; in the detail Save and Cancel; search field (`.searchable`) over names, keywords, tags and body.
- Later slices attach: menu-bar extra (pinned popover), picker panel, Settings scene. All use `AppModel`.

## Command map
| Command | Menu | Shortcut | Enabled when |
|---|---|---|---|
| New Snippet | File | Cmd-N | library open |
| Save Snippet | File | Cmd-S | editor dirty and valid |
| Duplicate Snippet | File | Cmd-D | a snippet is selected |
| Pin / Unpin Snippet | File | Shift-Cmd-P | a snippet is selected |
| Delete Snippet | File | Delete key in the list (no menu shortcut: Cmd-Delete belongs to text editing) | a snippet is selected |
| Undo Delete | Edit > Undo (system) | Cmd-Z | right after a delete |
| Find | Edit | Cmd-F | library open (focuses search) |
| Cancel edit | none | Esc | editor open |
Row context menu: Duplicate, Pin/Unpin, Delete (same actions, same enablement). Every control has an accessibility label; list rows read "name, keyword, pinned". Everything is reachable by keyboard (Tab, arrows, Return, Space, Esc).

## Empty states (each recoverable by keyboard)
| State | Message | Action |
|---|---|---|
| Empty library | "No snippets yet" | New Snippet (default button) |
| No results | "No results for “query”" | Clear Search (default button; Esc in the field also clears) |
| Empty Pinned / Recently Used / tag | "Nothing pinned yet" etc. with a one-line hint | Show All Snippets |
| No selection | "Select a snippet or create one" | none |
| Recently Deleted empty | "Nothing deleted" | none |

## Dirty edits
Leaving an edited editor by selecting another snippet, New, Cancel, closing the window or quitting asks once: Save, Discard Changes, Keep Editing (a sheet on the window). Save failure keeps the editor open and says why.

## Accessibility and motion
VoiceOver labels on icon-only buttons, toggle state on bold/italic/underline/list buttons, errors and keyword feedback announced; semantic colors only (contrast follows the system, Increase Contrast safe); no custom animation (Reduce Motion safe); targets are system controls.

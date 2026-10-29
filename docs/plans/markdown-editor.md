# Plan: In-place Markdown Editor + Prompt Edit

## Goals

1. Double-clicking a `.md` file in the file inspector opens it in an in-place (WYSIWYG-style, marker-hiding) Markdown editor in a pane split to the right.
2. Selecting text in that editor → right click → "Prompt Edit…" → enter an instruction (e.g. "Make this shorter") → the instruction, file path and selection are injected into a running coding-agent session of the worktree (Claude Code, Codex, … — agent-independent), so the edit happens with the session's context.

## Non-goals

- Side-by-side source/preview editor.
- Headless `claude -p` editing (must run in the session's context).
- Remote (SSH) worktrees — the explorer is local-only already.
- Upstream contribution to supacode: this is a personal mod; the merge-friendliness rules below apply.

## Merge-Friendliness (Isolation from Upstream Code)

This is maintained on top of upstream supacode, so the feature must touch existing files as little as possible to keep rebases/merges cheap.

- All new code goes into separate files under `supacode/Features/Markdown/` (`Content/`, `BusinessLogic/`, `Reducer/`, `Views/`), tests into `supacodeTests/Markdown/`.
- Prefer extensions in new files over edits in place (e.g. `AppFeature+Markdown.swift`, `ContentState+Markdown.swift` helpers, a new `CompositeContentFactory.swift` instead of editing `TerminalContentBuilder`).
- Logic goes into new types (`MarkdownOpenRouter`, `PromptEditDispatcher`); existing files only get a one-line call or case that delegates to them.
- Unavoidable touch points in existing files (keep each a few lines, ideally one hunk per file):
  - `PaneLayout.swift`: `ContentKind.markdown`, `ContentState.markdown` + Codable branches (Swift enums can't be extended with cases).
  - The ~7 exhaustive `switch`es over `ContentState`/`ContentKind`: one delegating case each.
  - `AppFeature.swift`: one early-return in `openFileFromExplorer` delegating to the markdown router; one action case forwarding to the markdown/prompt-edit logic.
  - `supacodeApp.swift`: swap the factory for the composite factory.
  - `Tuist/Package.swift` / `Project.swift`: the package dependency.
  - Settings: one toggle.
- Mark touch points with a `// MARK: Markdown editor` comment so they are easy to find during conflict resolution.
- Do not refactor or reformat surrounding upstream code in the same changes.

## Library Choice

[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) (Apache 2.0, TextKit 2, AppKit `NSTextView` subclass, used in the Nodes app).

- Edits in place: markers hidden, revealed at caret.
- Preserves the raw Markdown text byte-for-byte (no parse/re-serialize like Milkdown/ProseMirror) → no diff noise, stable line numbers for prompt edits.
- Only the core `MarkdownEngine` product (+ optionally `MarkdownEngineCodeBlocks`); skip `MarkdownEngineLatex` (pulls SwiftMath).

Risks: pre-1.0 API, Swift 5.9 package under our Swift 6 strict concurrency. Mitigation: pin `exact:` version in `Tuist/Package.swift` (like all other deps), wrap behind a thin adapter (`MarkdownEditorView`) so a swap (fallback: `no-problem-dev/swift-markdown-view`) stays local.

### Modifying the library

If the engine needs changes, use a **GitHub fork**, pinned by exact revision in `Tuist/Package.swift`:

```swift
.package(url: "https://github.com/<you>/swift-markdown-engine", revision: "<sha>")
```

- Upstream every change as a PR to nodes-app; switch back to the upstream package once merged.
- Not the repo's `patches/` convention: that is applied at build time to git submodules (ghostty, zmx via `scripts/build-ghostty.sh`); Tuist resolves SwiftPM packages itself, so there is no clean hook to patch them.
- Not vendoring: loses upstream updates and adds a large foreign codebase. Only consider it if modifications become large and permanent.
- If this feature is meant to go upstream to supacode, a personal-fork dependency is unlikely to be accepted — land library changes in nodes-app first.

Spike first (½ day): add package, host the editor in a bare window, verify build with `make build-app`, Dynamic Type, system colors, dark mode, selection range API, and context-menu customization (`menu(for:)` override on the NSTextView). Also verify injection: does `paste + "\r"` submit in Claude Code/Codex, or is a separate Return key event required?

## Phase 1 — Markdown Content Kind

The layout layer is already content-agnostic (`TabContent` protocol, `ContentRuntime`, `LayoutContentFactory`); only `.terminal` exists today. Per CLAUDE.md, nothing markdown-specific goes into `LayoutFeature`.

### Model (`Features/Terminal/Models/PaneLayout.swift`)

- `ContentKind.markdown`
- `MarkdownContentState: Codable, Sendable { var relativePath: String }` (relative to the worktree root, so persistence survives worktree moves)
- `ContentState.markdown(MarkdownContentState)` + Codable branches
- Update the ~7 exhaustive `switch`es over `ContentState`/`ContentKind` (compiler-guided).

### Content (`Features/Markdown/Content/MarkdownContent.swift`, new feature folder)

`@MainActor final class MarkdownContent: TabContent` with `nonisolated deinit {}`.

- `startSession(at:)`: load file, create editor view → `renderer`.
- `hibernate()` / `tearDown()`: save if dirty, drop view and file watcher.
- `isBusy`: `true` when there are unsaved changes (reuses the busy-gated close confirmation).
- `chrome`: `TabChrome` with file name as title, `doc.text` icon, dirty dot.
- `snapshot()`: `.markdown(relativePath)`.

### Document handling (`Features/Markdown/BusinessLogic/MarkdownDocument.swift`)

- Load/save UTF-8, preserve trailing newline and line endings.
- Save: debounced autosave (injected clock) + `⌘S`; atomic write.
- File watcher (`DispatchSource.makeFileSystemObjectSource`, re-armed on rename/delete because agents and editors write atomically):
  - buffer clean → reload silently, keep caret/scroll position as far as possible
  - buffer dirty → inline banner "File changed on disk — Reload / Keep mine"
  - file deleted → banner, keep buffer, allow "Save As"
- Ignore watcher events caused by our own save (compare mtime/content hash).

### Factory wiring (`App/supacodeApp.swift`, `TerminalSurfaceRecipe.swift`)

`TerminalContentBuilder.factory()` switches on `request.content`; add `.markdown` → `MarkdownContentBuilder`. Cleaner: introduce a small composite factory that dispatches by kind to the terminal and markdown builders, so the terminal builder stays terminal-only.

### Opening from the explorer (`AppFeature.openFileFromExplorer`, `AppFeature.swift:971`)

- If extension ∈ {`md`, `markdown`, `mdx`?} and the worktree is local:
  - **One markdown pane per worktree** (decided):
  - If a markdown tab for that path already exists in the worktree → select/focus it.
  - Else if the worktree's markdown pane exists → add a tab there (avoid pane explosion).
  - Else → `splitPane(id: focusedPane, direction: .right, spec: NewTabSpec(content: .markdown(...)))`.
- Otherwise keep the current behavior (open-file script / default app).
- Setting (`SupacodeSettingsShared`): "Open Markdown files in built-in editor" (default on), so users with an open-file script keep control.
- Context menu "Open With" gets a "Supacode Editor" entry.
- Log `[USER] Opened markdown file in editor: <path>` via `SupaLogger`.

### Tests (reducer logic)

- `openFileFromExplorer` routing: md → split/select/reuse; non-md → unchanged; setting off → unchanged.
- `ContentState` Codable round-trip for `.markdown`; restore of a missing file.
- `MarkdownDocument` reload/conflict decisions as pure logic (no `Task.sleep`, `TestClock` for debounce).

## Phase 2 — Prompt Edit into an Agent Session (agent-independent)

### UX

1. Select text in the editor → right click → "Prompt Edit…". Context menu only, no hotkey (decided; also avoids touching upstream `AppShortcuts.swift`).
2. Popover anchored to the selection with a single-line `TextField` ("Describe the change…"), Return submits, Esc cancels.
3. If several agent sessions run in the worktree, a picker in the popover showing agent icon + tab title (default: last focused).
4. Menu item disabled with an explanatory tooltip when no agent session is running in the worktree.

### Agent independence

- Candidates come from `AgentPresenceFeature`, which already tracks every `SkillAgent` (claude, codex, copilot, opencode, …) per surface with a common `Activity` state — no agent-specific detection needed.
- The payload is plain language with a plain relative path, which every agent understands.
- Optional per-agent formatting hook (`PromptEditFormatter`, default = plain) for agents with a file-reference syntax (e.g. `@path` for Claude Code/Codex) — a small `switch` in a new file, not required for v1.

### Payload

One line, sent as bracketed paste followed by Enter (explicit edit wording: a bare "In <file>: …" made agents answer in the terminal instead of editing):

```text
Edit the file docs/foo.md in place, lines 12-18 (from "first words…" to "…last words"). Make the following change to this block: Make this shorter.
```

- Path relative to the worktree.
- Line range computed from the selection in the raw text (stable because the engine preserves source).
- Quoted boundary words only when the selection starts or ends mid-line (full quote if short); full selection is not pasted (multi-line paste into the TUI is fragile).
- Save the buffer before sending, so the agent reads what the user sees.

### Targeting & timing (gate = agent presence)

Injection is a terminal mechanism; `AgentPresenceFeature` is only used to pick the target and as a safety gate.

- Candidate sessions: `AgentPresenceFeature` records whose surface belongs to the worktree (any agent; requires that agent's Supacode hooks to be installed).
- Send only when activity is `idle` or `awaitingInput` — this also guarantees text never lands in a plain shell or a busy TUI. If `busy`/`compacting`, queue the prompt and send on the next transition to idle (show "queued" state in the editor toolbar, cancellable). Drop the queue if the session ends.
- New action lives on the markdown content side / `AppFeature`, not in `LayoutFeature`. No NSNotification.

### Injection (terminal mechanism)

Existing path: `TerminalClient.focusSurface(worktree, tabID:, surfaceID:, input:)` → `WorktreeTerminalManager` (wakes + selects tab, focuses surface) → `WorktreeContentHost.focusAndInsertText(input + "\r")` → `GhosttySurfaceView.sendText` → `ghostty_surface_text` → Ghostty `Surface.textCallback` → `completeClipboardPaste(text, allow_unsafe: true)`.

So injected text is treated as a **paste** (bracketed-paste-wrapped if the TUI enabled that mode, which agent TUIs do). Consequences:

- The trailing `\r` ends up *inside* the bracketed paste → a TUI may treat it as a literal newline instead of submit. Unverified for Claude Code/Codex — check in the spike.
- Fix: send the text via `sendText` (paste), then submit with a **separate synthesized Return key event** (`ghostty_surface_key`, press + release).
- The existing path always steals focus. Add a non-focusing variant so the editor keeps focus (option: "Focus agent after sending").

Implementation (merge-friendly): new `TerminalInjector` in a new file (`Features/Markdown/BusinessLogic/`), working on `ContentRuntime.content(for: surfaceID)?.renderer as? GhosttySurfaceView`, with `paste(_:)` and `submit()`; one new `TerminalClient.Command` case only if routing through the client is required. Does not wake hibernated tabs — a session reported `idle` by presence has a live surface; otherwise fall back to `focusSurface`.
- Log `[USER] Prompt edit sent: <agent> <path> lines a-b` (no prompt text in release logs).

### Result

The agent edits the file → file watcher reloads the clean buffer (Phase 1). Nothing extra needed.

### Tests

- Target selection (0/1/n sessions, mixed agents, wrong worktree).
- Queueing: busy → queued → idle → sent exactly once; cancel.
- Payload formatting (line range, quoting/escaping, relative path with spaces).

## Decisions

| Question | Decision |
|---|---|
| Markdown pane reuse | One markdown pane per worktree; files open as tabs in it |
| Prompt Edit hotkey | None — context menu only |
| Supported agents | Agent-independent: any `SkillAgent` tracked by `AgentPresenceFeature` |
| Upstream contribution | Personal mod only; keep merge-friendly |

## Effort Estimate

| Step | Estimate |
|---|---|
| Spike (library integration) | 0.5 d |
| Phase 1 (content kind, document, watcher, routing, tests) | 3–4 d |
| Phase 2 (popover, targeting, queueing, injection, tests) | 2 d |

## Implementation Status (2026-10-29, branch `markus-mods`)

Implemented as planned; all new code under `supacode/Features/Markdown/` (`Content/`, `BusinessLogic/`, `Reducer/`, `Views/`), touch points in upstream files marked `// MARK: Markdown editor`.

Deviations from the plan:

- No tests: `markus-mods` skips test upkeep. The pure logic is testable as is (`MarkdownOpenRouter`, `MarkdownDiskReconciliation`, `MarkdownTextCodec`, `PromptEditPayload`, `PromptEditTargeting`, `PromptEditQueue`).
- Setting: app storage key `markdownEditorEnabled` (`SupacodeSettingsShared/Markdown/`), not a field of the settings file; toggle in Settings → Scripts.
- Explorer: a separate "Open in Supacode Editor" context-menu item (shown for `.md`/`.markdown`/`.mdx`), reached through the `openInMarkdownEditor` environment value instead of threading a callback.
- Deleted file: banner offers "Recreate File" (no "Save As").
- Readiness: `error` counts as ready (the TUI is back at its prompt), besides `idle` / `awaitingInput`.
- One queued Prompt Edit per editor; a newer one replaces it.
- Editor focus moves layout pane focus (`contentRequestedFocus`), so ⌘W and friends target the editor's pane.
- `MarkdownEngineCodeBlocks` not added (core `MarkdownEngine` 0.15.0 only).
- Not verified yet: whether paste + separate Return submits in Claude Code / Codex (the spike step); test manually.

## Read Mode (2026-10-30)

- Toggle per editor: floating button top-right, or ⌘/ while the editor has focus (shift tolerated, so ⇧⌘7 on German layouts works).
- Read mode passes the engine `isEditable: false` and a copy of the text with soft line breaks joined (`MarkdownSoftBreaks`): each joined `\n` becomes a space, so the copy has the source's UTF-16 length and selections map 1:1 to the file. Line-based approximation: no joins across blank lines, block starts (heading, list, quote, table, rule, HTML), code, hard breaks, or setext underlines. Quote continuations (`> a` / `> b`) stay separate.
- Prompt Edit works in both modes; line numbers are computed from the source text, not the text view.
- Scroll position: the top visible line's character index is captured before the toggle and restored after the engine re-lays out (`MarkdownScrollAnchor`).
- Appearance: separate overrides for edit and read mode (Same as App / Light / Dark), app storage `markdownEditModeAppearance` / `markdownReadModeAppearance`, pickers in Settings → Scripts. Applied as the hosting view's `NSAppearance`, so the engine's system colors follow it.
- Editors open in read mode; ⌘/ or the button switches to edit mode.
- Theme: Settings → Scripts → "Editor theme" (System / GitHub). GitHub is adapted from Typora's `github.css` (`MarkdownEditorStyle`): bundled Open Sans (woff2 under `Features/Markdown/Resources/Fonts`, registered per process), 16 pt base scaled with Dynamic Type, line-height 1.6, heading sizes, link/text/rule colors in light appearance (system colors in dark), list indent, code size 0.9, 860 pt reading column, 30 pt padding, white background. Not representable without engine changes: h1/h2 rules, h6 and blockquote text colors, table and code backgrounds/borders, width media queries. Paragraph spacing per source line is 0, so edit and read mode share line spacing.

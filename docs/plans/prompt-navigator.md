# Plan: Prompt Navigator (Conversation View from the Agent Transcript)

## Introduction

Agent TUIs like Claude Code draw their own viewport on the alternate screen, so Ghostty has no scrollback: a navigator that scrolls the terminal to a prompt cannot work (verified: search does not find text Claude has scrolled out of view).

Instead, Supacode reads the agent's own transcript (Claude: session JSONL under `~/.claude/projects/`) and shows the conversation in a read-only Markdown pane with a prompt list. Clicking a prompt scrolls the rendered conversation to it.

## Goals

1. For the focused agent tab, open a **Conversation** pane split to the right: a prompt list on the left, the rendered conversation (prompts + assistant text) on the right.
2. Clicking a prompt scrolls the conversation to that turn.
3. The pane updates live while the agent works.
4. Independent of the TUI's rendering mode and of terminal scrollback; survives zmx reattach.

## Non-Goals

- Scrolling the terminal itself.
- Remote (SSH) worktrees: the transcript lives on the remote host.
- Agents other than Claude in the first version (parser is behind a protocol, see "Agent Independence").
- Editing, rewinding or re-sending prompts (possible later via the existing `TerminalInjector`).
- Rendering tool results; tool calls show as one line.

## Merge-Friendliness

Same rules as `markdown-editor.md`: new code under `supacode/Features/Conversation/` (`BusinessLogic/`, `Content/`, `Reducer/`, `Views/`), extensions in new files, upstream touch points a few lines each and marked `// MARK: Conversation view`.

Touch points:

- `AgentPresenceOSC.swift` / `ClaudeHookSettings.swift`: the transcript signal (emit + parse).
- `WorktreeContentHost.handleContextSignal`: one branch delegating transcript signals.
- `PaneLayout.swift` and the exhaustive `ContentState`/`ContentKind` switches: `.conversation` case, next to `.markdown`.
- `CompositeContentFactory.swift` (already ours): build conversation content.
- `AppFeature`: one action forwarding to `AppFeature+Conversation.swift`; menu/hotkey entry.

## Flow

### 1. Surface → transcript path (hook signal)

The hook payload already carries `transcript_path` and `session_id`; `stopApiErrorProbeShell` extracts them today.

- New OSC 3008 metadata shape, disjoint from presence and notify: `kind=transcript;path=<base64>;sid=<session_id>`.
- Emitted by Claude's `SessionStart` (covers startup, `/clear`, `resume`, `compact`, which all switch session files) and `UserPromptSubmit` (covers sessions started before the hooks were updated). Composed into the existing commands, reusing the one stdin read.
- Path capped so the sequence stays under libghostty's 2048-byte OSC buffer (paths over the cap are dropped, not truncated).
- `AgentPresenceOSC.parseTranscript` (single source of truth, like `parseNotify`); `WorktreeContentHost` stores the latest path per surface on the terminal content side (exposed observable, not layout state).
- Only accepted for local surfaces (`pid` present, file exists under `~/.claude/projects/`), since the signal is unauthenticated.
- Users must re-install the Claude integration in Settings after the update (installed hook commands are not refreshed automatically).

Fallback (later): for a surface without a signal, take the newest JSONL in `~/.claude/projects/<encoded worktree path>/`, only when unambiguous (one Claude tab in the worktree).

### 2. Transcript parsing (`ClaudeTranscriptParser`)

The JSONL is append-only, one object per line.

- Read incrementally: remember the byte offset of the last complete line; on change, parse only the new tail.
- User prompt: `type:"user"`, not `isMeta`, not `isSidechain`, content is a string or text blocks. Skip `tool_result` content, `<command-name>` / `<local-command-stdout>` entries, and compaction summaries (`isCompactSummary`) (or show them as a marker).
- Assistant: `type:"assistant"`, `text` blocks rendered, `tool_use` as `▸ Tool: <short input>`, `thinking` skipped. Lines with the same `message.id` merge into one message.
- Output: `[ConversationTurn]` (id = prompt entry `uuid`, prompt text, timestamp, assistant blocks). Pure value type.
- Field names are verified against real transcripts in the spike; unknown shapes are skipped and logged at debug level.

### 3. Rendering (`ConversationDocument`)

- Turns are rendered into one Markdown string: per turn a heading or quote with the prompt, then the assistant text. Each turn's character offset is recorded.
- Shown in the existing `MarkdownEditorView` in read mode (`isEditable: false`), with the editor theme and appearance settings.
- On live update: append when only the last turn changed or new turns came in; keep the scroll position unless the view was at the bottom (then follow).

### 4. Navigator and scrolling

- Prompt list: `List` of the first line of each prompt (+ time), selected turn highlighted.
- Click → scroll the text view to the turn's character offset (reuse `MarkdownScrollAnchor`).
- Scrolling the conversation updates the highlighted prompt (top visible turn).

### 5. Opening

- Command "Show Conversation" (menu + hotkey, tooltip) for the focused terminal tab, enabled when its surface has a transcript path; via `FocusedAction`.
- Opens one conversation pane per source tab, split to the right like the Markdown editor. The content stores the source surface id, so it follows `/clear` and session switches.
- When the source tab closes, the pane keeps the last transcript (read-only snapshot) until closed.

## Agent Independence

`TranscriptSource` protocol (`transcriptPath` signal + `parse(lines:) -> [ConversationTurn]`). Claude first; Codex next (its hook payload also carries `transcript_path`; rollout JSONL format differs). Agents without a transcript file don't show the command.

## Risks

- **Transcript format is internal to Claude Code** and changes without notice. Mitigation: tolerant parser, skip unknown entries, keep the parser in one file.
- **Large transcripts** (MBs, mostly tool results): tool results are not rendered; verify MarkdownEngine performance with a long conversation in the spike, cap to the last N turns if needed.
- **Hook cost**: one more `printf` in `UserPromptSubmit`; stays within the 2 s hook deadline.

## Decisions to Make

1. Navigator placement: list inside the conversation pane (recommended, no upstream inspector change) vs. a third inspector pane next to Git/Files (`WorktreeInspectorPane`, upstream file).
2. Show tool calls as one-liners (recommended) or hide them.

## Effort Estimate

| Step | Effort |
| --- | --- |
| Spike: real transcript shapes, MarkdownEngine with long text | ½ day |
| Hook signal emit/parse + per-surface storage | ½ day |
| Parser + incremental reader + watcher | 1 day |
| Content kind, pane, rendering, navigator, scrolling | 1–1½ days |
| Menu/hotkey, settings toggle, polish | ½ day |
| **Total** | **3½–4 days** |

No tests on `markus-mods`; the parser and document builder stay pure so they are testable later.

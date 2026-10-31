# Plan: External Prompt Edit (Typora + PopClip)

## Introduction

Prompt Edit (see `markdown-editor.md`) lets a user select text in Supacode's built-in Markdown editor, type an instruction ("make this shorter"), and have it injected into a running coding-agent session of the worktree. The agent then edits the file with the session's context.

This plan brings the same workflow to external Markdown editors, starting with Typora. The user selects text in Typora, clicks a PopClip button, types the instruction, and Supacode delivers it to an agent session exactly as the built-in editor does.

The design keeps the external part as independent of Supacode as possible: a PopClip extension and a small standalone helper do the capture, matching and prompting, and Supacode only gains one CLI entry point that accepts a fully resolved request.

## Goals

1. From Typora, select text → PopClip button "Prompt Edit" → enter an instruction → the instruction, file path and selected source lines reach an agent session of the matching worktree.
2. Resolve the selection to exact source line numbers locally, so the agent does not have to search for the text.
3. Keep the helper editor-agnostic where possible: Typora is the first source, not a hard dependency.
4. Reuse Supacode's existing Prompt Edit pipeline (targeting, readiness queue, payload, injection) unchanged.

## Non-Goals

- Typora plugins (`typora_plugin` and similar): not supported on macOS, and patching the signed app bundle breaks on every update.
- Injecting into terminals via Accessibility / synthesized keystrokes (other terminals, VS Code). Possible later as an alternative delivery backend; see "Alternatives Considered".
- Exact selection position inside the document: neither PopClip nor macOS Services expose it (see "Duplicate Matches").
- Remote (SSH) worktrees.

## Components

| Component | Owner | Responsibility |
| --- | --- | --- |
| Typora | third party | Shows the document; the user selects text. |
| PopClip extension `PromptEdit.popclipext` | new, standalone | Shows the button in Typora, passes selection, Markdown conversion and app info to the helper. |
| Helper `prompt-edit-helper` | new, standalone | Reads the document path, matches the selection to source lines, shows the prompt dialog, calls the Supacode CLI. |
| `supacode` CLI | Supacode, extended | New `prompt-edit` command: lists targets, submits a request. |
| Supacode app | Supacode, extended | Resolves worktree and target, queues and injects via the existing Prompt Edit pipeline. |

## Flow

### 1. Trigger — user, PopClip

1. The user selects text in Typora; PopClip shows its bar.
2. The extension's action is limited to Typora (`requirements`/app filter on `abnerworks.Typora`) and requests `captureHtml`.
3. On click, PopClip runs the extension's shell script with `POPCLIP_FULL_TEXT`, `POPCLIP_MARKDOWN` and `POPCLIP_BUNDLE_IDENTIFIER`, which launches the helper with these values.

### 2. Document path — helper, Accessibility

4. The helper reads `AXDocument` of Typora's front window (a `file://` URL) via System Events / AX API. Verified working outside the sandbox.
5. If no path is available (untitled document, permission missing), the helper shows an error and stops.

### 3. Locate — helper, matcher

6. Read the file from disk.
7. Preprocess the source: drop link/image targets (`](…)`), reference link labels and definitions, HTML tags, HTML comments and footnote markers.
8. Normalize the source to letters and digits only, lowercased, keeping a map from each kept character to its source offset.
9. Normalize the selection the same way (prefer `POPCLIP_MARKDOWN`, fall back to `POPCLIP_FULL_TEXT`).
10. Search all occurrences:
    - one match → use it;
    - several matches → the dialog asks which one (see "Duplicate Matches");
    - no match → send the raw selected text instead of a line range.
11. Map the match to a one-based inclusive line range, plus start/end excerpts if the selection begins or ends mid-line.

### 4. Prompt input — helper, dialog

12. The helper asks Supacode for targets: `supacode prompt-edit --list-targets --file <path>`.
13. A small floating panel shows:
    - a preview of the selection and the resolved lines;
    - the occurrence picker, if there are duplicates;
    - the target picker (last focused session preselected);
    - the instruction text field.
14. Cancel stops the flow; Return submits.

### 5. Delivery — helper → Supacode CLI

15. The helper calls:

    ```bash
    supacode prompt-edit --file <abs-path> --lines 12-14 \
      [--from "<excerpt>" --to "<excerpt>"] [--text "<raw selection>"] \
      [--target <target-id>] --prompt "<instruction>"
    ```

16. The CLI finds the running app via its socket discovery and forwards the request.

### 6. Injection — Supacode app

17. Resolve the worktree as the longest worktree path containing the file; unknown file → error.
18. Resolve the target: the given `--target`, otherwise `PromptEditTargeting`'s first choice.
19. Build a `PromptEditSelection` and the instruction via `PromptEditPayload`.
20. Enqueue it in the existing Prompt Edit queue: ready → inject now, busy → wait, session gone → drop with error.
21. `TerminalInjector` pastes the instruction and sends Return.
22. The CLI reports the outcome (`sent`, `queued`, error); the helper shows it briefly and closes.

## Matching Details

- Whitespace, emphasis markers, headings, list and quote markers, table pipes, code fences and backslash escapes disappear through normalization; no Markdown parser is needed.
- Constructs whose hidden parts contain letters must be removed before normalizing (step 7); otherwise selections spanning them fail to match.
- Known non-matching cases: math, diagrams, HTML blocks rendered differently, Typora's auto-generated content (TOC). These fall back to raw text.
- Very short selections (e.g. a single word) often match several times; the duplicate picker handles them.

## Duplicate Matches

Neither PopClip nor macOS Services provide the selection's position or surrounding text, so duplicates cannot be resolved automatically. The dialog lists every match with its line number and some surrounding source text, and the user picks one. With a single match, which is the common case, no extra step is shown.

## Supacode Interface

New CLI command `prompt-edit` (in `supacode-cli/Commands/`), backed by a new socket query and deeplink action:

| Call | Result |
| --- | --- |
| `prompt-edit --list-targets --file <path>` | JSON list of targets (id, agent, activity, tab title) of the file's worktree; error if no worktree contains the file. |
| `prompt-edit --file … --prompt … (--lines … \| --text …)` | Submits; prints `sent` or `queued`, non-zero exit code on error. |

Errors: Supacode not running, file outside any worktree, no agent session, target gone.

The app-side code follows the merge-friendliness rules of `markdown-editor.md`: new files under `supacode/Features/Markdown/`, one delegating case at each touch point.

## Permissions and Security

- The helper needs Accessibility permission to read `AXDocument`. When launched by PopClip, attribution may go to PopClip (which already has it); to verify.
- The CLI talks to Supacode only through the existing per-user socket in `/tmp/supacode-<uid>/`; no network access.
- The instruction is typed into an agent session verbatim; it carries the same trust as typing it there directly.

## Alternatives Considered

- **Typora plugin (`typora_plugin`)**: would give exact selection and context menu integration, but does not support macOS and requires patching `window.html` in the app bundle.
- **macOS Service instead of PopClip**: works without third-party software, but is less discoverable and lacks `POPCLIP_MARKDOWN`. Can be added later as a second trigger for the same helper.
- **Accessibility injection into any terminal**: works with other terminals and VS Code (activate window, paste, Return), but loses target selection, readiness checks and focus, and clobbers the clipboard. Kept as a possible fallback delivery backend.
- **Matching inside Supacode**: would couple the helper to Supacode; keeping it in the helper lets other delivery backends reuse it.

## Open Questions

- Helper form: a small Swift app (SwiftUI panel, AX access) vs. a script with `osascript` dialogs. The duplicate and target pickers favor a Swift app.
- Accessibility attribution when the helper is launched by PopClip.
- Whether `POPCLIP_MARKDOWN` from Typora's HTML is close enough to the source to improve matching over plain text.
- Whether `--list-targets` should also report sessions of other worktrees, if the file lies outside every worktree.

## Phases

1. Supacode: `prompt-edit` CLI command, socket query and app handling.
2. Helper: AX path lookup, matcher, CLI calls; a minimal dialog.
3. PopClip extension.
4. Helper: duplicate and target pickers, status feedback.

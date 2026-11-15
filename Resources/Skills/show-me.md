---
name: show-me
description: Open a file in Supacode's editor, optionally selecting the relevant lines. Use whenever the user asks to see code or a file, with or without /show-me, e.g. "show me the file where you fixed the bug", "show me where the token gets refreshed", "open AppFeature.swift", "point me to that function", "highlight the change", inside a Supacode terminal session. Prefer this over pasting code into the chat.
---

# Show Me

Open the file most relevant to the current conversation in Supacode's editor
and select the passage you are talking about, so the user sees it right away.

## How

1. Decide what to show from the text after `/show-me`, or from the request
   itself when the user asked in plain words ("show me the file …"):
   - **Nothing:** the file and passage the conversation is about right now,
     the code you just explained, changed, or referred to.
   - **A file name or path** (`AppFeature.swift`, `src/app.ts:120`): that file.
     Resolve a bare name to the matching file in the worktree, preferring one
     discussed in the conversation; if several match and the conversation
     doesn't settle it, ask which one. Open it without a selection unless a
     selection is requested explicitly (a line or range in the argument) or the
     request itself is about a specific passage.
   - **A description** ("the file where you fixed the bug", "where the token
     gets refreshed"): find the match from the conversation first, then by
     searching the code. Select a passage only when the description points at
     one ("where the token gets refreshed"), not when it names a file ("the
     file where you fixed the bug").
2. If you select a range, get exact line (and, if useful, column) numbers from
   the file as it is on disk now. Read the file to confirm them; never guess.
3. Run:

```sh
supacode show <file> --from <line>[:<column>] --to <line>[:<column>]
```

- `<file>` may be relative to the current directory or absolute. It must lie
  inside the worktree of the Supacode terminal you run in.
- Lines and columns are 1-based. `--to` is inclusive. A position without a
  column covers the whole line, so `--from 10 --to 20` selects lines 10–20.
- Omit `--to` to select a single line (`--from 42`), or omit both to just open
  the file.

4. Reply with one short sentence saying what is shown (and selected, if
   anything) and why it matters.
   Don't repeat the code in the chat.

## Rules

- Show one passage per call. To walk through several places, call
  `supacode show` once per place, in order, and explain each one briefly.
- Prefer a tight range: the function, block, or few lines that matter, not a
  whole file.
- If the command fails (for example the file does not exist, or you are not in
  a Supacode terminal), tell the user and give the path and line range in plain
  text instead. The command succeeds without confirming that Supacode opened the
  file; a file outside this terminal's worktree is silently ignored.

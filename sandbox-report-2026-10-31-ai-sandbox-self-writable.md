# Sandbox gap report — ai-sandbox repo is writable from inside the sandbox

- **Date:** 2026-10-31
- **Project:** /Users/markus.loeffler.extern/loffler.local/programming/_external/supacode
- **Launcher:** sclaude
- **Verdict:** sandbox-caused (over-permission, not a blocked operation)

## What was attempted

Nothing failed. The user asked whether the session can write to the `ai-sandbox` repo, which holds
the sandbox's own launchers and profiles. A write probe succeeded, which means a sandboxed agent
can modify its own sandbox policy.

## What failed

No operation was blocked. The finding is that this probe **succeeded**:

```sh
f=/Users/markus.loeffler.extern/loffler.local/programming/ai/ai-sandbox/.write-test-$$; touch "$f" && echo WRITABLE && rm "$f"
```

```text
WRITABLE
```

## Root cause

The effective `filesystem.allowWrite` contains
`/Users/markus.loeffler.extern/loffler.local/programming/ai`, which includes
`programming/ai/ai-sandbox`. No `denyWrite` entry covers that repo. The only relevant denies are
`./claude-token` (relative to the cwd, so it doesn't protect `ai-sandbox/claude-token` from another
project), `~/.ai-sandbox`, and `./.sbuild.json`.

Writable security-sensitive files include:

- `profiles/*.json` (allow/deny lists, network domains)
- `sclaude`, `scopilot`, `sandbox-common.zsh`, `merge-settings.py` (launcher code that runs
  **outside** the sandbox before `srt` starts)
- `sbuild` (a daemon that runs outside the sandbox)
- `.srt-custom/` (the custom `srt` build itself)
- `claude-token` (as far as its readability goes, reads are only denied when `ai-sandbox` is the cwd)

## Effective policy at the time

Source: the sandbox system prompt injected into this session (authoritative), cross-checked
against `ai-sandbox/profiles/base.json`.

- `allowWrite`: `.`, `/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`, `~/.claude`,
  `~/.claude.json`, `…/programming/libs`, `…/programming/xcode/EasyLib`, **`…/programming/ai`**
- `denyWrite`: `./claude-token`, `~/.ai-sandbox`, `./.sbuild.json`

The `…/programming/ai` entry isn't in any repo `profiles/*.json`. It most likely comes from a user
profile under `~/.ai-sandbox/profiles/` selected by `~/.ai-sandbox/config.json`, which can't be
read from inside the sandbox, so its exact source is unconfirmed.

## Proposed change

Add the repo to `denyWrite` (and deny reading its token) in the same fragment that grants
`…/programming/ai`:

```json
{
  "filesystem": {
    "denyRead": [
      "~/loffler.local/programming/ai/ai-sandbox/claude-token"
    ],
    "denyWrite": [
      "~/loffler.local/programming/ai/ai-sandbox"
    ]
  }
}
```

Alternatively, put it in `profiles/base.json`. That would also block sessions whose cwd is
`ai-sandbox`, because deny wins over the `.` allow. For working on `ai-sandbox` itself, either run
`claude` unsandboxed there, or keep the deny in the user fragment and leave that fragment out for
that one project.

## Security impact of the change

This tightens the policy. The agent loses write access to `ai-sandbox` only: it can no longer edit
profiles, launcher scripts, `sbuild`, or the custom `srt` build, and can no longer read the stored
OAuth token from other projects. Without the change, a prompt-injected agent could, for example,
add `~` to `allowWrite` or enable open networking, or inject code into `sclaude`. That code would
run unsandboxed on the next launch and would also reach `sbuild`.

## Workarounds without changing the policy

- Drop the `…/programming/ai` write grant entirely and add only the subdirectories that need it.
  The downside is that you have to list them one by one.
- Make the repo read-only at the OS level (`chmod -R a-w`). The downside is that you have to
  toggle it every time you edit the repo, and the agent could `chmod` it back unless the path is
  also denied.

## How to verify the fix

1. `sclaude debug-settings` shows the new `denyWrite` entry.
2. In a new sclaude session from another project, this should fail with `Operation not permitted`:

   ```sh
   touch ~/loffler.local/programming/ai/ai-sandbox/.probe
   ```

3. `cat ~/loffler.local/programming/ai/ai-sandbox/claude-token` should also fail.

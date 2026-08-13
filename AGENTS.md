`CLAUDE.md` is a symlink to this file — editing either changes both.

## Commands

```bash
make                    # list all targets
make doctor             # verify prerequisites (mise, submodules, Zig-linkable Xcode, Metal toolchain)
make build-app          # build Debug app; regenerates the Tuist workspace when manifests change
make run-app            # build and launch Debug
make test               # all four test bundles in parallel (TEST_PARALLEL=NO to serialize)
make check              # swift-format + swiftlint
make log-stream         # stream app logs (subsystem app.supabit.supacode)
make install-dev-build  # copy the Debug build to /Applications
```

Requires [mise](https://mise.jdx.dev/); `mise install` once fetches the pinned tuist, zig, swiftlint, swift-format, and xcbeautify. Use the Make targets rather than raw `tuist` / `xcodebuild`: they own the generation stamps, the quiet `doctor` preflight, and per-build `DEVELOPER_DIR` selection.

### Running a single test

The workspace is generated, so it must exist first (`make generate-project`):

```bash
xcodebuild test -workspace supacode.xcworkspace -scheme supacode-tests \
  -destination "platform=macOS" -derivedDataPath .build/DerivedData \
  -only-testing supacodeFeatureTests/AppFeatureDeeplinkTests \
  CODE_SIGNING_ALLOWED=NO -skipMacroValidation | mise exec -- xcbeautify
```

- Tests live in four bundles, assigned by filename glob in `Project.swift`: `supacodeFeatureTests` (`AppFeature*`, `RepositoriesFeature*`), `supacodeGitTests` (`Git*`, `AgentHook*`, `ShellClient*`, real subprocess suites), `supacodeTerminalTests` (`Ghostty*`, `Layout*`, `SplitTree*`, `WorktreeTerminalManager*`, `Zmx*`), `supacodeTests` (everything else). Name a new test file so it lands in the intended bundle. The split exists because most tests are MainActor-bound — one bundle would cap the suite at a single main thread.
- **A new test file requires project regeneration.** Test targets use explicit globs expanded at generation time, so an unregenerated new file silently runs in no bundle. `make test` handles this; a raw `xcodebuild test` does not.
- App sources use Tuist buildable folders, so new non-test files need no regeneration.
- On failure `make test` dumps the assertion text from `build/supacode-tests.xcresult`; the streamed log only reports "Test case … failed".

### Xcode 26.3 on macOS 26.4+

GhosttyKit builds with pinned Zig 0.15.2, whose linker cannot link the macOS 26.4+ SDK (that SDK dropped the `arm64-macos` slice from `libSystem.tbd`), failing with a wall of `undefined symbol`. Install Xcode 26.3, which ships the macOS 26.2 SDK; `scripts/select-developer-dir.sh` pins it per build, so no global `xcode-select` is needed. The one-time `-license accept` / `-runFirstLaunch` / MetalToolchain commands are in the README.

## Architecture

Supacode is a macOS terminal emulator for running multiple coding agents in parallel, each in its own git worktree, with libghostty as the terminal and [zmx](https://zmx.sh) for background session persistence.

### Targets (`Project.swift`)

- **`supacode`** — the app. Buildable folders: `App/`, `Clients/`, `Commands/`, `Domain/`, `Features/`, `Infrastructure/`, `Support/`.
- **`SupacodeSettingsShared`** — settings models and `@Shared` persistence keys, `ShellClient` (+SSH), coding-agent hook installers, `SupaLogger`, `SupacodePaths`. Everything else depends on it.
- **`SupacodeSettingsFeature`** — the Settings window (reducers + views).
- **`supacode-cli`** — the `supacode` binary, embedded in the app bundle and installed by `CLIInstaller`.
- **`GhosttyKit`** — Tuist `foreignBuild` of `ThirdParty/ghostty` through `scripts/build-ghostty.sh` (Zig; slow, fingerprint-cached).
- Four unit-test bundles (see above).

### Reducer tree

`AppFeature` (`Features/App/Reducer/AppFeature.swift`) scopes `terminals`, `repositories`, `agentPresence`, `settings`, `updates`, `commandPalette`. `RepositoriesFeature` owns the sidebar — repos, worktrees, PR state, notifications — and is split across `RepositoriesFeature+*.swift` extensions.

### Terminal layering

- **Value world**: `LayoutFeature` state holds panes, tabs, splits (`SplitTree`), selection and zoom — `ContentID`s only, no renderers.
- **Reference world**: `WorktreeTerminalManager` (`@Observable`, `@MainActor`, not a reducer) owns one `WorktreeContentHost` per worktree and bridges back into TCA by pushing coalesced, deduped `TerminalClient.Event`s into the store. `ContentRuntime` is the process-wide dependency registry mapping `ContentID` → live `TabContent`.
- `TabContent` (`Features/Terminal/Content/`) abstracts a tab's session — `startSession` / `hibernate` / `tearDown` / `snapshot` — and exposes anything the tab strip displays through observable `TabChrome`.

### Clients (swift-dependencies)

`supacode/Clients/*` wrap the outside world: `GitClient` (worktrees, status, branches), `GithubCLIClient` / `GithubIntegrationClient` (`gh` plus GraphQL PR state), `ZmxClient` (session daemon, OSC scanning, IPC framing), `TerminalClient`, `WorktreeInfoWatcherClient`, `DeeplinkClient`, `FileExplorerClient`, `UpdaterClient` (Sparkle), `WorkspaceClient`.

### Control plane

- `AgentHookSocketServer` listens on `/tmp/supacode-<uid>/pid-<pid>` for JSON `{"deeplink": …}` commands and `{"query": …}` reads from `supacode-cli`, which finds the socket through `$SUPACODE_SOCKET_PATH` (exported into every session) or by scanning live pids.
- Agent presence and notifications do **not** use that socket: installed agent hooks emit OSC 3008 (`AgentPresenceOSC`), which also works over SSH.
- Deeplinks (`supacode://…`) are the shared command vocabulary for the CLI, hotkeys, and other apps.

### Persistence

`~/.supacode/` (`SupacodePaths`) holds worktrees, per-repository settings, and layouts. Read them through `@Shared` keys (`.settingsFile`, `.repositorySettings(_:host:)`, the layout keys) rather than new dependency clients.

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies / Sharing**: Dependency injection and shared persisted state
- **ArgumentParser**: `supacode-cli`
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Code Guidelines

- Target macOS 26.0+, Swift 6.0
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- SwiftLint runs with `strict: true` and two custom rules that fail the build: views must not mutate `store.…` directly (send actions), and `@Shared` / `@SharedReader` must not be constructed inside a view body, computed property, or function (references are cached weakly, so the key's disk read re-runs every evaluation) — hold it as a private stored property or resolve it in the reducer.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.
- Avoid top-level free functions. Default to `static` methods, computed properties, or instance methods on a relevant type (enum/struct/extension). Free functions pollute the module namespace, are harder to discover, and easily drift from the inline implementation a consumer ends up writing instead. If the operation is pure and stateless, make it a `static` on a caseless `enum` or the most relevant type, not a top-level `func`.
- Closure-typed focused values invalidate the AppKit menu on every body run (closures have no Equatable conformance, so SwiftUI re-publishes every time). Always wrap menu-bar action closures with `FocusedAction<Input>` and publish via `.focusedSceneAction(_:enabled:token:perform:)` / `.focusedAction(_:enabled:token:perform:)`. The wrapper dedupes on `(isEnabled, token)`, so AppKit only rebuilds the menu when something the menu actually displays changes. Token rules in `App/Models/FocusedAction.swift`: set `token` to a hashable projection of any captured state that affects behavior; leave it `nil` when the closure captures only the store / `@State` bindings. Consumers should read the action with `@FocusedValue(\.x)` and gate with `action?.isEnabled != true`, not `action == nil`.
- Sidebar rows must not fan out invalidation. Per-row state lives in `RepositoriesFeature.State.sidebarItems` so a per-leaf mutation (notification tick, agent activity, running-script update) invalidates only that leaf, not every sibling. The view renders the cached `state.sidebarStructure` (computed in the reducer's post-reduce hook), never reading `sidebarItems[id:]` from a view body; derive per-leaf data in `computeSidebarStructure(...)`, not in the view.
- Never lift content-specific (e.g. terminal-only) mechanics or state into the layout layer. `LayoutFeature` owns topology and strip mechanics only (panes, tabs, selection, focus, zoom, rename identity); anything a specific content kind produces (agent badges, progress, script locks, busyness) lives on the content side, exposed to the strip through the content's observable `TabChrome` (`Features/Terminal/Content/TabChrome.swift`), never as layout reducer state or actions.

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- Do not open a pull request unless the user explicitly asks for one. Commit to the working branch and let the user decide when to push and open a PR.
- When the user does ask you to open an issue or pull request, follow the templates in `.github`: fill the bug or feature issue form, and use the pull request template (link the issue with `Closes #<number>`, complete the checklist, and disclose any AI tools you used). A human is the author of record: never set an AI agent as a commit author or co-author.

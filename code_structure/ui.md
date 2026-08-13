# UI structure

Orientation doc for the SwiftUI/AppKit view layer. Companion docs will cover other areas as this folder grows.

All UI is TCA-driven (`@Bindable var store: StoreOf<Feature>`). Views send actions; they never mutate `store.…` directly (enforced by a custom SwiftLint rule).

## Scenes (`supacode/App/supacodeApp.swift`)

`SupacodeApp` declares every window/scene the app owns:

- **`Window("Supacode", …)`** — the main window, hosts `ContentView`. One per launch (`WindowID.main`).
- **`Window("Settings", …)`** — `SettingsView`, opened via `CommandGroup(replacing: .appSettings)` or a deeplink.
- **`Window("Deeplink Reference", …)`** — `DeeplinkReferenceView`, static reference content.
- **`Window("CLI Reference", …)`** — `CLIReferenceView`, static reference content.
- **`MenuBarExtra`** — `MenuBarNotificationsMenu`, the menu-bar notification list (`.menuBarExtraStyle(.window)`, styled to look like a menu since a native `NSMenu` can't host rich rows).
- **`.commands { … }`** — the app's menu bar: `WorktreeCommands`, `SidebarCommands`, `TerminalCommands`, `TerminalTabSelectionCommands`, `WindowCommands`, `UpdateCommands`, plus inline `CommandGroup`s for command palette / worktree switcher / quit.

`SupacodeAppDelegate` (`NSApplicationDelegate`) handles process-level events (launch, activation, deeplink URLs, quit-time layout persistence) and forwards them into `AppFeature` via `store.send(...)`.

## Main window: `ContentView`

`supacode/App/ContentView.swift` is the root view for the main window:

```
NavigationSplitView
├── sidebar:  SidebarView            (repositories/worktrees list)
│   └── safeAreaInset(.bottom): SidebarBottomCardView
└── detail:   WorktreeDetailView     (toolbar + selected worktree's terminal area)
```

It also hosts window-scoped concerns as invisible background views so their observation scope doesn't invalidate the rest of the tree:

- `CommandPaletteOverlayHost` — builds palette items and drives the floating `CommandPalettePanel`.
- `WindowTitleHost` — computes `.navigationTitle` from sidebar/selection state.
- `OpenActionIconWarmHost` — warms the "Open With" icon cache.
- `WindowTintBackdrop` / `WindowChromeObserver` / `WindowTitleHost` — sync window chrome to the focused terminal's background color.

Each of these is its own small `View` struct specifically so a narrow slice of state (e.g. notification churn) invalidates only that host, not `ContentView.body` — a recurring pattern in this codebase (see also `ToolbarNotificationsButtonHost` below).

Sheets/alerts attached to `ContentView`: deeplink confirmation, worktree creation prompt, repository/worktree customization, rename branch — each keyed off a `@Presents`-style scoped store.

## Sidebar (`Features/Repositories/Views/`)

`SidebarView` wraps `SidebarListView` (the actual `List`/row rendering) and adds the toolbar "Add…" menu plus sheets for remote-connection and clone-repository forms.

Row-level views:

- `SidebarItemsView` / `SidebarItemView` — one row per repository/worktree/folder.
- `SidebarPingDots`, `PullRequestBadgeView`, `PullRequestChecksRingView` — per-row status decorations.
- `NotificationPopoverButton` / `NotificationPopoverView` — per-row/global notification popovers.
- `RepoSectionHeaderView`, `SidebarHighlightSectionsView` — section grouping/headers.
- `ArchivedWorktreeRowView` / `ArchivedWorktreesDetailView` — archived-worktree browsing.

**Perf-critical invariant:** per-row state lives in `RepositoriesFeature.State.sidebarItems`, and the view renders a reducer-precomputed `state.sidebarStructure`/cached slices — never `sidebarItems[id:]` directly from a view body — so a single leaf's mutation (a notification tick, agent activity) invalidates only that row, not the whole `List`. `SidebarView.body` explicitly comments on this for `archiveTargets`/`deleteTargets`.

## Detail pane (`Features/Repositories/Views/WorktreeDetailView.swift`)

The largest single view file; renders one of several bodies depending on state (`detailContent`):

- No worktree selected yet → `DetailPlaceholderView` (or `EmptyStateView` once load is complete).
- Archived-worktrees mode → `ArchivedWorktreesDetailView`.
- Multiple worktrees selected → `MultiSelectedWorktreesDetailView`.
- Worktree still creating/deleting → `WorktreeLoadingView`.
- Repository failed to load → `FailedRepositoryDetailView`.
- Worktree's working directory missing → `MissingWorktreeDetailView`.
- Normal case → **`WorktreeLayoutView`**, the actual terminal pane tree for the selected worktree.

It also owns:

- The **toolbar** (`WorktreeDetailToolbar` / `WorktreeToolbarContent`): branch/folder title, "Open With" menu, script-run menu, and trailing files/git/notifications toggle buttons. Shows a shimmering `ToolbarPlaceholderContent` skeleton while loading.
- The **inspector** (`.inspector(...)`): `WorktreeStatusInspectorContainer`, showing files / git+PR / notifications depending on `inspectorPane`.
- Window-scoped `.focusedSceneAction`/`.focusedAction` wiring for menu commands (open, reveal in Finder, new terminal, split, close tab, search, run script, …).

## Terminal layer (`Features/Terminal/`)

This is the "value world / reference world" split described in the top-level `AGENTS.md`. UI-wise:

```
WorktreeLayoutView              one worktree's terminal area
└── LayoutAlertHost              binds the layout's close-confirmation alert
    └── LayoutContentView        AppKit container (LayoutAXContainer) hosting the pane tree
        └── LayoutPaneTreeView
            └── PaneNodeView (recursive: split vs. leaf)
                ├── PaneSplitView → SplitView (draggable divider) → two PaneNodeViews
                └── PaneStripView (leaf)
                    ├── PaneTabStrip                 tab bar for this pane
                    └── ContentHostView              NSViewRepresentable mounting the live renderer
```

Key views/types:

- **`WorktreeLayoutView`** — per-worktree root; owns window-activity syncing and terminal auto-focus. Renders `EmptyTerminalPaneView` when the layout has no panes.
- **`LayoutContentView`** — wraps the pane tree in `LayoutAXContainer`, a stable `NSView` that exposes an ordered pane list to accessibility (`AXSplitGroup`) and survives SwiftUI structural rebuilds without reparenting live renderer views.
- **`PaneNodeView`** — recursive switch over `SplitTree<PaneID>.Node`: `.split` → `PaneSplitView`, `.leaf` → `PaneStripView` (or `WindowedPanePlaceholderView` if that pane popped into its own window).
- **`SplitView`** (`Features/Terminal/Views/SplitView.swift`) — the generic two-child resizable split with a draggable divider; layout-agnostic.
- **`PaneStripView`** — one pane: `PaneTabStrip` (tab bar, `TabBar/`) above the selected tab's content (`ContentHostView`). Also renders drop zones (`PaneSplitDropZones`) for drag-to-split and the unfocused-pane dim overlay.
- **`ContentHostView`** — `NSViewRepresentable` that mounts/unmounts the actual renderer (`GhosttySurfaceView` wrapped in `GhosttySurfaceScrollView`, or another `TabContent`'s view) resolved from `ContentRuntime`. This is the seam where the reference world (`WorktreeTerminalManager`/`ContentRuntime`) meets SwiftUI.
- **`PaneWindowManager`** — manages panes popped out into their own `NSWindow`s ("window mode").

Tab-bar visuals live under `Features/Terminal/TabBar/` (`TerminalTabBarColors`, `TerminalTabBarMetrics`, `TerminalTabBackground`, `TerminalTabDivider`, `TerminalTabTrailingButton`). A tab's live badges/progress/shimmer come from its content's observable **`TabChrome`** (`Features/Terminal/Content/TabChrome.swift`), not from `LayoutFeature` state — content-specific chrome is deliberately kept out of the layout reducer per the project's architecture rule.

## Settings window (`SupacodeSettingsFeature/Views/`)

Separate module, separate reducer (`SettingsFeature`). `SettingsView` is the root (sidebar of settings sections); per-section views: `AppearanceSettingsView`, `TerminalSettingsView`, `NotificationsSettingsView`, `WorktreeSettingsView`, `RepositorySettingsView`, `GlobalScriptsSettingsView`, `RepositoryScriptsSettingsView`, plus ones living in `supacode/Features/Settings/Views/` (`GithubSettingsView`, `DeveloperSettingsView`, `KeyboardShortcutsSettingsView`, `UpdatesSettingsView`) that depend on app-level clients and so couldn't move into the shared module.

## Command palette (`Features/CommandPalette/Views/`)

`CommandPaletteOverlayView` / `CommandPalettePanel` — a floating, non-window overlay (not a `Window` scene) toggled by `⌘K`-style shortcuts, listing worktrees/commands/scripts built from `CommandPaletteFeature.items(...)`.

## Cross-cutting UI conventions

- **Invalidation scoping**: wherever a small piece of state changes often (notifications, agent presence, per-row data), the code introduces a small dedicated view (`*Host`, `*ButtonHost`) that reads just that state, so the surrounding large view's `body` doesn't re-run. Look for this pattern before assuming a large view like `WorktreeDetailView` re-renders on every tick.
- **`FocusedAction`**: menu-bar/keyboard commands are wired through `@FocusedValue`/`.focusedSceneAction`/`.focusedAction` rather than direct bindings, so AppKit's menu only rebuilds when `(isEnabled, token)` actually changes (see `App/Models/FocusedAction.swift`).
- **NSViewRepresentable boundaries**: `LayoutAXContainer` and `ContentHostView` are the two places SwiftUI hands off to raw AppKit for terminal rendering; environment values (`GhosttyShortcutManager`, `CommandKeyObserver`, chrome text size) have to be explicitly re-published inside these because `NSHostingView` starts a fresh environment.
- **No custom colors** — system colors only; `.monospaced()` used where appropriate; Dynamic Type throughout (see root `AGENTS.md` UX Standards).

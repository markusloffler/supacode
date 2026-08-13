# Sidebar

Deep dive into the repository/worktree sidebar — the left column of the main window (see [ui.md](ui.md) for where it sits in the overall UI). All files below live under `supacode/Features/Repositories/`.

## Data flow, end to end

```
Disk (repos on filesystem) + git/SSH probes
        │  .loadPersistedRepositories / .repositoriesLoaded / .remoteRepositoryResolved
        ▼
RepositoriesFeature.State.repositories: IdentifiedArrayOf<Repository>
RepositoriesFeature.State.pendingWorktrees: [PendingWorktree]
        │  syncSidebar(&state)                              [RepositoriesFeature+Sidebar.swift]
        ├─ reconcileSidebarItems  → state.sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
        │      per-row TCA state; carries forward lifecycle/PR/diff/agents/notifications;
        │      mirrors title/color/isPinned from @Shared(.sidebar)
        └─ rebuildSidebarGrouping → state.sidebarGrouping: SidebarGrouping
               per-repo [.pinned/.unpinned/.archived: [SidebarItemID]] render-order

@Shared(.sidebar): SidebarState   (persisted user curation — sections/buckets/items,
                                    collapse flags, pin/unpin/archive, custom title/color)
        │  read together with sidebarItems + sidebarGrouping by:
computeSidebarStructure(groupPinned:groupActive:)            [SidebarStructure.swift]
        │  (invoked from recomputeSidebarStructureIfChanged(), Equatable-diffed)
        ▼
state.sidebarStructure: SidebarStructure    ← cached, single render source of truth
        ▼
SidebarListView.body reads state.sidebarStructure.sections
        ▼
SidebarSectionDispatcher → SidebarGitRepositorySection / SidebarFolderRow /
   SidebarFailedRepositorySection / SidebarHighlightSection / placeholder
        ▼
SidebarItemsView (walks SidebarItemGroup.rowIDs, applies branch-nesting if enabled)
        │  store.scope(state: \.sidebarItems[id: rowID], ...)
        ▼
SidebarItemRow → SidebarItemView   (pure rendering of one SidebarItemFeature.State)
```

The rule this enforces: **views never derive the tree themselves** — they only walk a value (`SidebarStructure`) that the reducer already computed and diffed. This is the sidebar-specific instance of the "sidebar rows must not fan out invalidation" rule from the root `AGENTS.md`.

## The persisted model: `SidebarState` (`BusinessLogic/SidebarState.swift`)

`SidebarState` is `Codable`/`Equatable`/`Sendable`, saved to `~/.supacode/sidebar.json`. Its shape mirrors the rendered tree:

```
SidebarState
 ├─ schemaVersion: Int                                 (migration gate, currently v3)
 ├─ focusedWorktreeID: Worktree.ID?
 └─ sections: OrderedDictionary<Repository.ID, Section>  (one per repo)
     Section
      ├─ collapsed: Bool
      ├─ title / color: String? / RepositoryColor?      (repo customization)
      └─ buckets: OrderedDictionary<BucketID, Bucket>    (.pinned / .unpinned / .archived)
          Bucket
           ├─ items: OrderedDictionary<Worktree.ID, Item>
           └─ collapsedBranchPrefixes: Set<String>       (branch-nest collapse state)
               Item
                ├─ archivedAt: Date?   (non-nil only in the .archived bucket)
                ├─ title: String?      (per-worktree custom title)
                └─ color: RepositoryColor?
```

Mutations (`move`, `insert`, `pin`, `unpin`, `archive`, `unarchive`, `remove`, `reorder`, …) are all O(1) by construction — `SidebarState` is the single source of truth for pin/order/archive state, mutated only by the reducer via `state.$sidebar.withLock { ... }`, never directly by views.

`Item.archivedAt` doubles as the sole "is this archived" signal; `pin`/`unpin` route through `removeAnywhere` first so an accidental double-bucket state (an item present in two buckets) self-heals instead of being assumed away.

## Persistence (`BusinessLogic/SidebarPersistenceKey.swift`, `SidebarPersistenceMigrator.swift`)

- `@Shared(.sidebar)` is backed by a `SidebarKey` (`SharedKey`) that reads/writes `~/.supacode/sidebar.json` (`SupacodePaths.sidebarURL`) with an atomic temp+rename writer.
- A decode failure renames the corrupt file aside (`sidebar.json.corrupt-<ISO8601>`) before falling back to an empty `SidebarState`, so a later save from empty state can't silently clobber recoverable bytes.
- There is no external-change watcher (`subscribe` is a no-op) — the app is the sole writer.
- Three chained one-shot migrations run at boot, before `RepositoriesFeature.State` exists (`SupacodeApp.init`):
  1. **v0→v1**: folds seven legacy `UserDefaults`/`settings.json` sources (`sidebarCollapsedRepositoryIDs`, `repositoryOrderIDs`, `worktreeOrderByRepository`, `lastFocusedWorktreeID`, `archivedWorktreeDates`, `archivedWorktreeIDs`, `settings.pinnedWorktreeIDs`) into `sidebar.json`. Gated on `schemaVersion >= 1`, not file existence, so a crash mid-migration retries.
  2. **v1→v2**: drains the retired `global.remoteRepositories` and strips legacy `folder:`/`remote://` ID prefixes from every persisted ID across settings, layouts, and sidebar.
  3. **v2→v3**: normalizes a trailing-slash bug in remote IDs (gh-764).

Three View-menu toggles persist separately, in `UserDefaults` via `@Shared(.appStorage(...))`, **not** in `sidebar.json`: `sidebarNestWorktreesByBranch`, `sidebarGroupPinnedRows`, `sidebarGroupActiveRows` (all default `true`), plus `worktreeRowHideSubtitleOnMatch`.

## The cache pipeline (`RepositoriesFeature.swift`, `SidebarStructure.swift`)

This is the mechanism that makes "recompute the tree, but only when something relevant changed" both automatic and exhaustive.

1. `CacheInvalidations` is an `OptionSet`: `.sidebarStructure`, `.selectedWorktreeSlice`, `.sidebarSelectionSlice`, `.toolbarNotificationGroups`, `.openActionResolution` (+ `.allSidebar`, `.all`).
2. **Every** `RepositoriesFeature.Action` case and **every** `SidebarItemFeature.Action` case has an exhaustive `cacheInvalidations` switch — no `default:`, so adding a new action case without classifying it is a compile error. Examples: `.lifecycleChanged` → `[.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]`; `.agentSnapshotChanged` → `.sidebarStructure` only; `.dragSessionChanged` → `[]` (pure UI, touches no cache).
3. A trailing `Reduce` block chained onto `RepositoriesFeature.body`, after the main switch and the `.forEach(\.sidebarItems, ...)` child reducer, reads `action.cacheInvalidations` and calls `state.applyCacheRecomputes(invalidations)`.
4. `applyCacheRecomputes` dispatches to `recomputeSidebarStructureIfChanged()` and its four siblings — each **Equatable-diffed against the previous cached value**, so a same-value rebuild never triggers a SwiftUI observation invalidation. `.openActionResolution` instead prunes a dictionary and kicks off an async effect, since resolving touches disk and "a reducer must not touch disk."
5. Gated by `@Dependency(\.sidebarStructureAutoRecompute)` (default `true`; a few legacy tests opt out). Runs synchronously and unbatched on every matching dispatch — there's no debounce.

So: nothing in the view layer ever triggers a recompute. `SidebarListView`'s `.onChange` handlers for the grouping toggles just `send` marker actions (`.sidebarGroupingTogglesChanged`, `.sidebarNestByBranchChanged`) whose sole job is to arm this same post-reduce hook.

## Row lifecycle: `SidebarItemFeature` (`Reducer/SidebarItemFeature.swift`)

One instance per worktree/folder row, held in `RepositoriesFeature.State.sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>`. This is the array views `store.scope` into (`\.sidebarItems[id: rowID]`) to bound observation to a single row.

Key `State` fields:

- Identity: `id` (= `Worktree.ID`), `repositoryID`, `kind` (`.gitWorktree` / `.folder`).
- Display: `name`, `branchName`, `subtitle`, `workingDirectory`, `customTitle`/`customTint` (mirrors `SidebarState.Item`).
- Flags: `isMainWorktree`, `isPinned`, `isAttached`, `isMissing`, `host: RemoteHost?` (nil = local — the discriminator most consumers branch on alongside `kind`).
- `lifecycle`: `.idle` / `.pending` / `.archiving` / `.deletingScript` / `.deleting`.
- Live data: `addedLines`/`removedLines`, `pullRequest`, `runningScripts`, `agentSnapshot`, `notifications`, `unseenSurfaces`, `hasUnseenNotifications`, `allTabsDormant`, `isDragging`.

Every action handler is `guard state.x != next else { return .none }` — cheap no-op suppression so a redundant update never invalidates observation.

Rows are **born and killed only** by `RepositoriesFeature.reconcileSidebarItems` (called from `syncSidebar`) — never by a per-row action. `reconcileSidebarItems` rebuilds `sidebarItems` from the live `repositories` roster + `pendingWorktrees`, carrying forward existing per-row state (lifecycle, PR, diff, agents) for surviving IDs, and deliberately **keeps in-flight rows alive** whose worktree just vanished mid-archive/mid-delete, so their completion handlers can still drain.

This file also defines several small value types used across the row/detail cascade: `WorktreeAccent`, `SidebarDisplayName` (the name-fallback cascade), `SelectedWorktreeSlice` (cached focused-row projection, excludes agents/notifications so per-leaf churn on the focused row doesn't invalidate the detail pane), `SidebarContextRow` (what the context menu is built from — it never resolves a `Worktree` from the parent), `SidebarSelectionSlice` (`rows`, `archiveTargets`, `deleteTargets`, `hasMixedKindSelection`).

## Views

### `SidebarView.swift`
Thin wrapper: hosts `SidebarListView`, the "Add…" toolbar menu (local folder / remote / clone), sheets for the remote-connection and clone forms, and the focused actions for archive/delete/confirm-worktree.

### `SidebarListView.swift`
The actual `List(selection:)`. Reads `state.sidebarStructure.sections` and dispatches each `SidebarStructure.Section` case (via a private `SidebarSectionDispatcher`) to the matching subtree: `SidebarGitRepositorySection`, `SidebarFolderRow`, `SidebarFailedRepositorySection`, `SidebarBlockedRepositorySection`, `SidebarHighlightSection`.

Notable mechanics:

- `.onMove` is attached **once**, on the outer `ForEach(structure.sections)`, in the flat "all sections" index space — reorder logic translates offsets into "repo index space" via `structure.reorderableRepositoryIDs` before sending `.repositoriesMoved`. Non-repo sections carry `.moveDisabled(true)` so they can never be a drag source.
- `shortcutHintByID` is the one legal piece of view-side computation in this file (per its own comment): a join between the reducer-derived `structure.slotByID` and live `commandKeyObserver.isPressed`, empty unless Cmd is held.
- `SidebarRightArrowMonitor` — an `NSEvent` local monitor working around `NSOutlineView` (List's backing view) swallowing the right-arrow key before SwiftUI's `.onKeyPress` sees it; used to focus the terminal of a sole selected worktree.
- `revealPendingSidebarWorktree` — a `.task(id: pendingSidebarReveal?.id)` that yields twice (letting newly-expanded rows materialize) before scrolling via `ScrollViewProxy`.
- Folders render as `Section { SidebarFolderRow } header: { EmptyView() }` specifically so `.listStyle(.sidebar)` doesn't visually merge two consecutive folder rows.

### `SidebarItemsView.swift`
Walks one repository's `[SidebarItemGroup]` (already reducer-ordered) and renders each group either flat or, when branch-nesting is enabled, via `SidebarBranchNesting.buildRows`. Owns per-bucket drag-reorder (`.pinnedWorktreesMoved`/`.unpinnedWorktreesMoved`), translating visible (post-hoisting) `.onMove` offsets back into full-bucket index space through `SidebarItemGroup.translateFilteredMove`.

- `SidebarRowMoveMode`: `.alwaysDisabled` / `.alwaysEnabled` / `.conditional` — folder rows route to the outer repo-level `.onMove`; pinned/unpinned rows are conditional on the row not currently removing/terminating.
- `.onMove` is only attached when branch-nest grouping is inactive — a no-op `.onMove` still steals the repo-level reorder gesture, and grouping suppresses reorder for the whole bucket (a cross-group drag would just snap back).
- `SidebarPathGroupAggregatedIndicators` (branch-nest group headers) scopes each descendant leaf individually via `store.scope`, feeding a pure snapshot array into `SidebarBranchNesting.aggregateIndicators`, so a per-leaf storm invalidates only this small subview. The code explicitly cites a prior regression (commit `0a1ed578`) as the reason not to read `sidebarItems` from the parent store here.
- `SidebarItemRow` → `SidebarItemContainer` → `SidebarItemBody` is the chain that scopes one row's `StoreOf<SidebarItemFeature>`, attaches `.tag(SidebarSelection.worktree(rowID))`, the context menu, and `.onDragSessionUpdated`.
- `SidebarItemContextMenu` is the entire right-click menu: open-with / reveal-in-Finder, pin/unpin, copy pathname/branch name, rename branch, customize appearance, folder settings, archive/delete — bulk-aware via `store.sidebarSelectionSlice`.

### `SidebarItemView.swift`
Pure presentation for one row: icon (branch/PR/folder/lifecycle), title + subtitle, trailing badges (diff stats, PR badge + check-status overlay, running-agent avatars, notification/running-script dot, shortcut hint). Driven entirely by `StoreOf<SidebarItemFeature>` plus a few view-supplied overrides (`hideSubtitle`, `displayNameOverride`, `nestDepth`, `highlightSubtitle`).

- `SidebarNestLayout` — shared indent/chevron-width constants, used by both this file and the group headers in `SidebarItemsView`, keeping leaf icons and group chevrons baseline-aligned.
- `ResolvedRowDisplay` — pure value type computing `name`/`subtitle`/`accent` from raw store fields, including the "hide subtitle when it duplicates the branch name" logic.
- Most subviews (`TitleView`, `IconView`, `TrailingView`, `StatusIndicator`, …) are `Equatable` so SwiftUI's diffing skips re-render when their narrow input hasn't changed. Any subview reading `@Environment(\.backgroundProminence)` deliberately overrides `==` to ignore the environment, since SwiftUI tracks environment changes separately — worth knowing before adding a new `Equatable` subview here.

### `SidebarSelection.swift`
The `List`'s selection tag type: `.worktree(Worktree.ID)` / `.archivedWorktrees` / `.failedRepository(Repository.ID)`. `RepositoriesFeature.State.sidebarSelections` is the reducer-side mirror the `List`'s binding reads/writes.

### `SidebarHighlightSectionsView.swift` + `RepoSectionHeaderView.swift`
`SidebarHighlightSection` renders the two global "Pinned" / "Active" sections from an already-ordered `[Worktree.ID]` supplied by `SidebarStructure` — no classification or sorting happens in the view. `RepoSectionHeaderView` renders a repo's native `Section` header (name, remote glyph, in-flight spinner for removal/SSH resolution).

## Interactive features

- **Selection** — single (`List` binding → `.selectionChanged`) and multi-select (`sidebarSelectedWorktreeIDs: Set<Worktree.ID>`), a dedicated cached `sidebarSelectionSlice` feeding the context menu, in-memory back/forward history (`worktreeHistoryBackStack`/`ForwardStack`), and hotkey-slot navigation with live Cmd-held shortcut hints.
- **Drag reorder** — repo rows (`.repositoriesMoved`) and per-bucket pinned/unpinned rows (`.pinnedWorktreesMoved`/`.unpinnedWorktreesMoved`), both index-translated to survive hoisting/branch-nesting. Reordering is confined within one bucket/repo; there's no drag-between-sections. Cross-app file/folder drag (`.dropDestination(for: URL.self)`) is how new repositories get added.
- **Context menu** — open-with, reveal in Finder, pin/unpin, copy pathname/branch name, rename branch, customize appearance, repo/folder settings, archive, delete — all bulk-aware, built from value-typed projections rather than live lookups.
- **Pinning** — hoists a row into the global "Pinned" highlight section when `sidebarGroupPinnedRows` is on; a git main worktree can never be pinned (folders can).
- **Archiving** — moves a row into the `.archived` bucket with a timestamp; can transiently reappear mid-delete-script as a render-only backstop.
- **Folders vs. git worktrees** — unified by `SidebarItemFeature.State.Kind` and `Repository.isGitRepository`; a folder repo renders as one synthetic worktree row, not an expandable section.
- **Expand/collapse** — per-repository (`sidebar.sections[id].collapsed`) and per-branch-nest-group (`bucket.collapsedBranchPrefixes`), plus a global expand/collapse-all action.
- **Notifications/badges/PR status** — per-row unseen-notification dot, running-script color dots, agent avatars, PR icon + check-status badge, diff `+n/-n` counters, dormant marker — aggregated toolbar-wide via `ToolbarNotificationGroup` (`Models/ToolbarNotificationGroup.swift`), computed purely from `SidebarItemFeature.State`, not the live terminal manager.
- **Highlight sections (Pinned / Active)** — two global, user-togglable, cross-repository sections that hoist rows out of their home repo section; a repo with all its rows hoisted shows a muted "+N pinned, +N active" summary instead of duplicating them.

## Related model files

- `Models/WorktreePlacementOverride.swift` — optional `name`/`path` override for where a new worktree lands, threaded through the create-worktree actions and shared by the prompt UI, reducer, and CLI/deeplink entry points.
- `Models/ToolbarNotificationGroup.swift` — the notification-bell popover's data model plus `RepositoriesFeature.State.computeToolbarNotificationGroups()`, the pure function behind `toolbarNotificationGroupsCache`.

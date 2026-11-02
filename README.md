# DevClean

A small menu-bar app that keeps an eye on RAM, swap and disk on a dev Mac and
(eventually) cleans up the things that pile up: stale dev servers, caches, old
worktrees.

## Build and run

```bash
swift test                     # core logic tests
./scripts/bundle.sh            # build/DevClean.app (ad-hoc signed)
./scripts/bundle.sh --install  # also copy to ~/Applications
open build/DevClean.app
```

`swift run DevClean` also works for quick iteration, but "Launch at login"
needs the bundled app.

## Layout

- `Sources/DevCleanCore`: system reading, no UI. `SystemMetrics` (memory via
  `host_statistics64`, swap, disk, boot time), `ProcessScanner` (per-process
  footprint via `proc_pid_rusage`, grouped by app bundle), `Insights` (rules
  that turn a snapshot into warnings).
  `DevServerScanner` reads argv and cwd for likely processes, classifies dev
  servers and groups them by git checkout (or Postgres data dir);
  `ProcessStopper` sends SIGTERM (SIGINT for Postgres), waits, then SIGKILLs,
  re-checking each PID's start time so a reused PID is never hit.
- `Sources/DevClean`: SwiftUI `MenuBarExtra`, polling every 5 s. Protected
  folders and the stale cutoff are stored in `UserDefaults`.
- `Support/Info.plist`: bundle metadata (`LSUIElement`, so no Dock icon).
- Cleanup (`CleanupCatalog`, `CleanupRunner`): each target either empties a
  cache folder, removes old `name-<version>` folders, or runs the tool's own
  command (`uv cache clean`, `pnpm store prune`, `xcrun simctl …`). Deletes
  only real folders at least two levels inside home, refuses symlinks, and
  won't run while a blocking process (Xcode, Simulator, Playwright browsers…)
  is alive. Caches are deleted outright since they rebuild; nothing here goes
  to the Trash because that wouldn't free space. Every run is appended to
  `~/Library/Logs/DevClean/cleanup.log` (JSON lines).
- Worktrees (`Worktrees`): finds the repositories behind Codex worktrees (plus
  any added by hand) and lists their linked worktrees. One is removable only
  if it has no uncommitted or untracked changes, no commits missing from every
  remote, no process running inside it, and isn't locked or protected.
  Removal is plain `git worktree remove` (no `--force`), so git refuses too if
  anything changed since the check. Worktrees whose files iCloud has offloaded
  are left alone: `git status` would download every file. Last activity comes
  from the reflog entries, not file dates (`git gc` rewrites those).
- Large files (`LargeFileFinder`): Spotlight for home plus a walk of
  dot-folders (which Spotlight skips), ignoring phone/iCloud mounts. Files go
  to the Trash; anything under `~/Library` or open in a process (`lsof`) can
  only be revealed.

- Automation (`NotificationPolicy`, `AutoCleanPolicy`): warnings and critical
  insights become notifications (a warning at most once a day, a critical one
  every 6 hours, a worse one right away). Opt-in automatic cleanup, when free
  space is low or weekly and at most daily, runs only caches that rebuild
  themselves (uv, npm, pnpm unused, Bun, pip, Homebrew), skipping anything in
  use; uv also waits until no `uv` process runs. Settings live in the gear tab.

Read-only checks against this machine (they stop and delete nothing):

```bash
DEVCLEAN_LIVE=1 swift test --filter LiveDevServerScan
DEVCLEAN_LIVE=1 swift test --filter LiveCleanupPreview
DEVCLEAN_LIVE=1 swift test --filter LiveWorktreePreview
```

## Roadmap

| # | Scope | Status |
|---|---|---|
| M0 | Menu-bar scaffold, bundling, launch at login | done |
| M1 | Read-only dashboard: RAM, swap, disk, uptime, top apps/processes, insights | done |
| M2 | Dev-server finder (runserver, vite, esbuild, celery, postgres) with protected folders; stop gracefully | done |
| M3 | Storage tab: cache cleanup (uv, npm, pnpm, Bun, pip, Homebrew, DerivedData, simulators, old Playwright browsers) with preview, blockers, log | done |
| M4 | Worktree cleanup with safety checks (dirty, unpushed, in use, iCloud) and large-file finder | done |
| M5 | Notifications and scheduled safe cleanup | done |
| M6 | Developer ID signing and notarization | |

Space freed should be reported from free-space before/after, not file sizes:
APFS clones mean deleting a cache can free much less than its size (clearing
34.5 GB of uv cache freed about 10 GB).

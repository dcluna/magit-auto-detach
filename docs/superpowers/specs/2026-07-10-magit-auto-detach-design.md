# Magit Auto-Detach: Design Spec

## Problem

Rebasing a stack of branches with `--update-refs` fails when any branch in the
stack is checked out in a git worktree. Git refuses to rewrite a branch that's
currently checked out elsewhere.

Manual workflow: detach each worktree HEAD, rebase, re-checkout. This is tedious
and error-prone with many worktrees.

## Solution

A tool that automatically detaches worktrees for branches in a given ref range,
persists the mapping, and restores them on command. Integrates with magit for
ref selection.

## Architecture

```
~/ghq/github.com/dcluna/dotfiles/
├── elisp/
│   └── magit-auto-detach.el              ← magit UI integration
└── bin/
    └── magit-auto-detach/
        ├── mad-detach                     ← Ruby: detach worktrees, write state
        ├── mad-restore                    ← Ruby: restore worktrees, update state
        ├── mad-branches                   ← Ruby: list branches in ref range
        └── lib/
            └── mad/
                ├── state.rb               ← state file read/write/append
                └── git.rb                 ← git operations wrapper
```

- **Elisp** handles magit integration: interactive commands, ref selection via
  `magit-read-branch-or-commit`, transient menu entries.
- **Ruby scripts** handle all git operations: finding branches, detaching,
  restoring, state management.
- **State file** lives at `<git-common-dir>/magit-auto-detach.json` (resolved via
  `git rev-parse --git-common-dir`) — always the real `.git` directory, even when
  invoked from a worktree. Tool is project-agnostic.

## Ruby Scripts

### `mad-branches`

Finds all local branches pointing to commits in a ref range that are checked out
in worktrees.

```
Usage: mad-branches <base-ref> <tip-ref> [--repo <path>]
```

Output (JSON to stdout):
```json
[
  {"branch": "feat-a", "sha": "abc123", "worktree": "/path/to/wt-a"},
  {"branch": "feat-b", "sha": "def456", "worktree": null},
  {"branch": "feat-c", "sha": "ghi789", "worktree": "/path/to/wt-c"}
]
```

Preconditions:
- `base` must be an ancestor of `tip` (validated with `git merge-base --is-ancestor`)
- Tool assumes a **linear history** between base and tip. Merge commits in the
  range may cause unexpected branches to be included.

Algorithm:
1. `git log --first-parent --format=%H base..tip` → commits in range (linear)
2. For each commit: `git branch --points-at <sha>` → branches
3. Parse `git worktree list --porcelain` → map branch → worktree path. Only
   worktrees with a `branch` field are candidates; already-detached worktrees
   are ignored.
4. Return all matches; `worktree: null` for branches without a worktree

### `mad-detach`

Detaches worktrees for branches in range. Writes state incrementally.

```
Usage: mad-detach <base-ref> <tip-ref> [--repo <path>] [--dry-run]
Exit codes: 0 = success, 1 = failure (rollback attempted), 2 = rollback failed
```

Steps:
1. Find branches with worktrees (same logic as `mad-branches`)
2. If state file already exists, refuse with error (previous session not restored)
3. Create state file with metadata (created_at, base_ref, tip_ref, empty entries)
4. For each worktree with a branch:
   a. `git -C <worktree> checkout --detach`
   b. On success: append entry to state file **after** successful detach
   c. On failure: rollback all entries already in state file (all confirmed
      detached), exit 1 or 2
5. Print summary to stdout (JSON)

Note: entries are written after detach (not before) so the state file only
contains worktrees that are actually detached. If the process crashes between
a successful detach and the file write, one worktree may be detached without
a state record — `mad-restore` won't know about it. This is the safer
trade-off: rollback never attempts to restore a worktree that wasn't detached.

### `mad-restore`

Restores worktrees to their original branches. Updates state incrementally.

```
Usage: mad-restore [--repo <path>] [--dry-run]
Exit codes: 0 = all restored, 1 = partial restore
```

Steps:
1. Read state file; exit with message if absent
2. For each entry: `git -C <worktree> checkout <branch>`
3. On success: remove entry from state file
4. On failure: log error, continue with remaining entries
5. If state file empty after loop, delete it

### State file format

Location: `<git-common-dir>/magit-auto-detach.json` (via `git rev-parse --git-common-dir`)

```json
{
  "version": 1,
  "created_at": "2026-07-10T12:00:00Z",
  "base_ref": "develop",
  "tip_ref": "feat-c",
  "entries": [
    {"worktree": "/vagrant/api-feat-a", "branch": "feat-a"},
    {"worktree": "/vagrant/api-feat-c", "branch": "feat-c"}
  ]
}
```

When `--repo` is omitted, scripts default to the current directory's repo root
via `git rev-parse --show-toplevel`.

Lifecycle:
- `mad-detach` creates file, appends entries after each successful detach
- `mad-restore` removes entries as they succeed, deletes file when empty
- File is source of truth for "what still needs restoring"
- Survives Emacs restarts

Concurrency: single-user tool, no file locking. Running two `mad-detach`
invocations concurrently on the same repo is unsupported.

## Failure Handling

### Detach fails midway

Detached A, B successfully; C fails:
1. State file contains A, B (only successfully detached entries)
2. Rollback: `git -C <wt> checkout <branch>` for A and B only
3. If a rollback entry fails: log but continue rolling back rest
4. Delete state file after rollback
5. Exit 1 if rollback succeeded, exit 2 if rollback had failures

### Restore fails midway

Restored A; B fails:
1. A's entry removed from state file (already succeeded)
2. B's entry remains in state file
3. Log error for B, exit 1
4. User can fix (e.g. branch was deleted) and retry `mad-restore`

## Elisp Layer

### Commands

**`magit-auto-detach-detach` (interactive)**
- Reads two refs using `magit-read-branch-or-commit`
- Default base: rev at point. Default tip: current branch via `magit-get-current-branch`
- Calls `mad-detach <base> <tip> --repo <repo-root>`
- Repo root from `magit-toplevel`
- Shows result in message area

**`magit-auto-detach-restore` (interactive)**
- No arguments; calls `mad-restore --repo <repo-root>`
- Shows result (N restored, M failed)
- If no state file: "Nothing to restore"

**`magit-auto-detach-status` (interactive)**
- Reads state file, displays currently detached worktrees
- If no state file: "No active detach session"

### Magit transient integration

Entries under the worktree transient or a custom suffix:
```
W d  → Detach worktrees for rebase
W r  → Restore detached worktrees
W s  → Show detach status
```

### Script discovery

```elisp
(defcustom magit-auto-detach-bin-directory
  (expand-file-name "../bin/magit-auto-detach"
                    (file-name-directory (locate-library "magit-auto-detach")))
  "Directory containing mad-* Ruby scripts.")
```

All magit ref selection uses `magit-read-branch-or-commit` and related magit
functions — no custom ref reading.

### Error reporting

Script stderr + exit code displayed via `message` or `magit-process-buffer`.
Non-zero exit always surfaces to user.

## Testing

### Test infrastructure

- Project: `/Users/danielluna/Projects/magit-auto-detach/`
- Test repo: `/Users/danielluna/Projects/test-auto-detach-repo/` (created by fixtures)
- ERT tests for both elisp and integration (elisp → Ruby → git)

### Test repo fixture

```
test-auto-detach-repo/
├── main repo (branch: main)
│   commits: A ← B ← C ← D ← E
│   branches: main=A, feat-a=C, feat-b=D, feat-c=E
├── wt-feat-a/   (worktree on feat-a)
├── wt-feat-b/   (worktree on feat-b)
└── wt-feat-c/   (worktree on feat-c)
```

### Test cases

**Happy path:**
- `mad-branches` finds correct branches in range
- `mad-detach` detaches all worktrees, creates state file with correct entries
- `mad-restore` re-checkouts all branches, deletes state file
- Worktrees functional after restore

**Multiple branches same commit:**
- Two branches on same SHA, both with worktrees → both detached and restored

**No worktrees in range:**
- Branches exist but no worktrees → no-op, no state file

**Partial overlap:**
- Some branches have worktrees, some don't → only worktree'd ones detached

**Detach failure midway:**
- Simulate failure on 2nd worktree (e.g. read-only `.git`)
- 1st worktree rolled back to original branch
- State file cleaned up

**Rollback failure:**
- Detach A succeeds, B fails, rollback of A also fails
- Exit code 2, error describes both failures

**Restore failure midway:**
- Restore A succeeds, B fails (branch deleted)
- State file contains only B's entry
- A on correct branch

**Idempotency:**
- Detach with existing state file → refused with error
- Restore with no state file → clean message

**Elisp integration:**
- `magit-auto-detach-detach` calls scripts with correct arguments
- `magit-auto-detach-restore` parses output correctly
- `magit-auto-detach-status` reads and displays state

## Assumptions

- Any ref that resolves to a commit is valid as `base-ref` (tag, SHA, branch,
  remote ref). Only `tip-ref` branches and local branches in the range are
  considered for detaching.
- `git worktree lock` does not prevent checkout changes — locked worktrees are
  handled normally.

## Out of scope

- Automatic restore via magit hooks (manual only, per requirement)
- Handling bare repos or repos without worktree support
- Remote branch tracking
- Non-linear (merge-heavy) branch stacks

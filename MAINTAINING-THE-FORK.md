# Carrying this fork onto a new herdr release

This fork adds one thing to herdr: **a worktree row belongs to the space that
opened it**, and the sidebar groups by that owner instead of by repository. Every
upstream release has to be merged and the change re-established on top of it,
because upstream keeps moving the code it touches - between 0.8.2 and the merge
of 2026-09-05 the whole TUI moved from `src/app/input/` and `src/ui/` into
`src/client/shell/`, and the sidebar stopped reading `Workspace` structs
altogether.

So do not expect the patch to merge. Expect to re-apply an **invariant**, in the
places the new tree keeps it. This document is that invariant, its current
places, and the checks that prove it landed.

## The invariant, in five statements

1. `WorktreeSpaceMembership` carries `parent_workspace_id: Option<String>`,
   `#[serde(default)]`, persisted with the session.
2. When a worktree action opens or creates a row, the owner is stamped from the
   **source space** - `Some(source workspace id)` for a linked checkout, `None`
   for the space that owns rows.
3. A worktree action whose source is a linked checkout resolves to that row's
   owner instead of failing with `linked_worktree_source`.
4. The group key is the owner: a space that is not a linked worktree keys on its
   own id; a row keys on `parent_workspace_id`, and when that is absent falls
   back to the first unlinked member on the same repository key, then to the
   repository key itself. **One function is the authority, and everything that
   groups, collapses, closes or reorders asks it.**
5. The owner leaves the process: `workspace.list`, `worktree.list` and the client
   shell snapshot all carry `parent_workspace_id`, optional and omitted when
   absent, so a stock peer sees what it always saw.

## Where each statement lives

Paths as of the 2026-09-05 merge (upstream `af7e189b`). When a path is gone, find
its replacement by the symbol, not by the file.

| # | symbol | file |
| --- | --- | --- |
| 1 | `WorktreeSpaceMembership`, `worktree_group_key` | `src/workspace.rs` |
| 2 | `mark_worktree_membership`, `worktree_membership` | `src/app/api/worktrees.rs` |
| 2 | membership construction on the TUI paths | `src/app/worktrees.rs` |
| 3 | `resolve_worktree_source` | `src/app/api/worktrees.rs` |
| 4 | `workspace_group_key`, `workspace_entries`, `parent_group_key`, `displayed_workspace_status` | `src/client/shell/sidebar.rs` |
| 4 | group toggle, context menu wording | `src/client/shell/context_menu.rs` |
| 4 | dragging a group as a block | `src/client/shell/mouse.rs` |
| 4 | close-group confirmation | `src/client/shell/overlay_input.rs` |
| 4 | `workspace_close_indices` | `src/app/actions.rs` |
| 5 | `WorkspaceWorktreeInfo`, `WorktreeInfo` | `src/api/schema/workspaces.rs`, `src/api/schema/worktrees.rs` |
| 5 | `ClientShellWorktree` and its producer | `src/protocol/wire.rs`, `src/server/client_shell.rs` |

A grep that finds most of the work in a fresh tree:

```bash
grep -rn "worktree.key\|member.key == space.key\|repo_key" src | grep -v tests
```

Every hit that decides *which spaces belong together* is a place the invariant
has to be re-established. Hits that merely identify a repository are fine.

## The merge, step by step

```bash
git fetch upstream --tags
git merge upstream/master
```

Conflicts fall into three kinds, and each has one right answer:

- **A file upstream deleted.** Accept the deletion (`git rm`) and re-apply the
  behaviour in whatever file now owns it. Never resurrect the file.
- **A file upstream rewrote around our hunk.** Take upstream's
  (`git checkout --theirs`), then re-apply the invariant on top. Resolving hunk
  by hunk against a refactor produces code that compiles and means nothing.
- **A fixture missing `parent_workspace_id`.** Add `parent_workspace_id: None`.
  The compiler lists every one of them; do not hunt for them by hand.

Then let the compiler drive: `cargo build` names each construction site, and
`cargo test --no-run` names each fixture and every upstream signature that
changed under us.

## What must pass before it is installed

Run these on the pinned toolchain (`rust-toolchain.toml`); a Homebrew cargo
ignores it:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=$(awk -F'"' '/^channel/ {print $2; exit}' rust-toolchain.toml)

cargo test --bin herdr client::shell            # grouping, collapse, drag, menus
cargo test --bin herdr app::api::worktrees      # owner stamping, source resolution, API
cargo test --bin herdr api::schema              # the generated protocol artifact
cargo test --bin herdr app::actions             # close-group
```

Four tests are the fork's own and must exist after any port. If a refactor
deletes them, rewrite them where the behaviour now lives rather than dropping
them:

| test | what it pins |
| --- | --- |
| `rows_group_under_the_space_that_opened_them` | two agents on one repository keep their own rows |
| `a_row_without_an_owner_falls_back_to_the_repository_parent` | a row from an older build still groups |
| `api_snapshots_name_the_space_that_opened_the_row` | the owner reaches both listings |
| `api_worktree_open_from_a_row_resolves_to_its_owner` | statement 3 |

Two more rules learned the hard way:

- **A test that collapses a group must ask for the key**, never write a literal
  repository key. Upstream's own collapse tests did, and they passed while
  asserting nothing after the group key changed. Seed them from
  `workspace_group_key` / `worktree_group_key`.
- **Changing an API type means regenerating the schema artifact**:
  `HERDR_UPDATE_API_SCHEMA=1 cargo test --bin herdr generated_protocol_schema_artifact_is_current`,
  and commit the result.

### Known red, not caused by the fork

Reproduce these on a pristine upstream checkout before spending time on them:

- `app::api::plugins::tests::*` - one of them fails in a module run and passes
  alone. They share the machine's real `~/.config/herdr/plugins`. Which one
  fails depends on what is installed there.
- The whole binary run ends in `signal: 13, SIGPIPE` after a couple of thousand
  tests. It aborts the process, so tests after it never run; skipping
  `pty::` and `server::client_transport` gets further.
- The macOS jobs of `Build artifacts (manual)` fail in `build.rs`: Zig cannot
  link libghostty-vt against the runner's SDK (`undefined symbol: _abort`,
  `__availability_version_check`). Confirmed identical on pristine `master`,
  2026-09-04. macOS binaries come from `scripts/build-herdr-local.sh` on the
  machine itself; CI is only useful for the Linux musl artifact.

## Installing and proving it live

```bash
scripts/build-herdr-local.sh          # release build, installs to ~/.local/bin/herdr by rename
```

The running server keeps its old inode, so the new build takes effect at the next
`herdr session stop <name>`. Prove the arrangement on a throwaway session rather
than on the one you work in:

```bash
herdr --session demo server &
# open two spaces on one repository, open a worktree row from each with
#   herdr worktree open --workspace <that space> --path <checkout> --label <name> --no-focus
herdr --session demo worktree list --cwd <repo> | jq '.result.worktrees[] | {open_workspace_id, parent_workspace_id, branch}'
```

Each row must name the space it was opened from. Then look at the sidebar: two
spaces, each with its own rows, and neither space drawn inside the other.

## Version and updates

`scripts/build-herdr-local.sh` stamps `<upstream version>-many-spaces.<commit>`
and pins `[update] version_check = false` in `~/.config/herdr/config.toml`,
because an accepted update prompt replaces the patched binary with a stock
release. For the same reason a stock client attached with `--remote` offers to
install its own version over the remote binary: attach with the patched client.

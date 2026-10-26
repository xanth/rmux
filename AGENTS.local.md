# RMUX patch set maintenance

A flat patch set of RMUX fixes. Each fix is its own branch, written to be
upstreamed to Helvesec/rmux, and merges onto a release tag beside the others.
A consumer runs the tag plus every fix until upstream ships them.

The fork is `xanth/rmux`, remote `xanth`. Placeholders: `<tag>` is the release
tag the set is based on (for example `v0.10.0`), `<fix>` is a fix name.

`<fork-point>` is `git merge-base <tag> origin/main`. Fixes start there, so a
pull request to upstream `main` carries only the fix, and merging the fix onto
the tag adds only the fix.

## Patch principles

Every patch must be:

- **Correct and complete**: it fixes the root cause in RMUX, on every platform
  the cause exists on, with a regression test where practical.
- **Robust**: it fails safely, keeps existing error paths for the cases it
  does not handle, and does not rely on timing.
- **Secure**: it keeps RMUX's security model. Pipes stay per-user and
  RMUX-derived, peer checks stay, no new unsafe code outside the crates and
  blocks that already allow it, each `unsafe` block with a `SAFETY:` comment.
- **Widely useful**: it helps RMUX users in general, not one consumer. A fix
  shaped around one consumer's workaround belongs in that consumer.
- **Respectful of upstream intent**: before a patch changes a deliberate
  upstream choice (a test that asserts the old behaviour, a commit or issue
  that explains it), find that intent in the history, keep it, and say in the
  commit message how the patch keeps it. If it cannot, drop the patch and
  solve the problem in the consumer.

## Repo layout

| Path | Content |
|---|---|
| `.` | Root checkout of upstream, remote `origin`. Read-only: any upstream branch, no patch commits |
| `.worktrees/xanth/<branch>` | One worktree per fix branch; the path matches the branch name |
| `.worktrees/patch-maintenance` | The `patch-maintenance` branch |
| `.worktrees/build` | Detached checkout of the tag plus every fix, made by `Build-PatchSet.ps1` |
| `AGENTS.local.md` | The consumer's private notes: machine setup, install folder. Untracked (`.git/info/exclude`) |

## Branches

| Branch | Base | Content |
|---|---|---|
| `fix/<fix>` | `<fork-point>` | One fix as a curated, linear commit series with code and tests |
| `patch-maintenance` | orphan | This file and the scripts. Never upstreamed; plain append-only history |

`Update-PatchSet.ps1` treats every `fix/*` branch as a fix.

## Series

| Fix branch | Problem | Platforms | Upstream status |
|---|---|---|---|
| `fix/windows-socket-path` | When RMUX runs as tmux, `-S <file path>` is refused on Windows, so tmux tools cannot name a private server. The tmux-compatible resolver maps the path to an RMUX-derived per-user pipe; the rmux CLI and SDK keep the refusal, and foreign pipe names stay refused | Windows | Helvesec/rmux#247 (closes #237). Upstream added the refusal in `9dd43c33` and points rmux users at `-L`; the patch keeps that for the rmux CLI and changes only the tmux drop-in surface, as the Claude swarm redirect does |
| `fix/windows-daemon-launch` | (1) Through the tiny dispatcher, a caller that captures output hangs until the daemon exits: the dispatcher's handles leak into the daemon. (2) Under a job that forbids breakaway (Task Scheduler, services, hosted CI), every daemon start fails; the daemon now starts inside a caller job that cannot kill it | Windows | Helvesec/rmux#248 (closes #238). (2) changes the policy of `7069f01e`; the patch keeps its rule (the daemon outlives the launcher). An explicit opt-in is the fallback if upstream wants one |
| `fix/queue-start-server` | `set-option … ; new-session` in one invocation fails: only the first command could start the server. The command that starts it now also supplies the start options (`--web-port`, `--frontend-url`) | All | Helvesec/rmux#252 (closes #244) |
| `fix/paste-carriage-return` | `paste-buffer` sends each CR as the two characters `\r` | All | Helvesec/rmux#249 (closes #239) |
| `fix/windows-lone-program-path` | (1) A lone pane command that is a program path with a space (`C:\Program Files\…`) is split by `cmd /S /C` and the pane exits. (2) Such a path, or a quoted first word, names the window and `#{pane_current_command}` `Program` | (1) Windows, (2) all | Helvesec/rmux#250 (closes #240) |
| `fix/dead-pane-exit` | (1) A Windows pane that exits during its deferred start never commits its exit; the exit now ends the start. (2) A format query could mark a kept pane dead before its exit committed, so the remain-on-exit message was skipped; queries now leave kept panes to the commit. (3) The remain-on-exit message is not drawn as tmux draws it, so `capture-pane -J` differs. (4) Reflow joins a wrapped row that is not full at its full width, so its unwritten cells become spaces; (3) makes such a row, and resizing a dead pane shows it | (1) Windows, (2)–(4) all | Helvesec/rmux#245 (closes #241, #242). (2) keeps `4a297ec2`'s prompt `pane_dead` for panes without remain-on-exit |
| `fix/control-ignore-size` | A control client cannot set `ignore-size` with `attach -f` or `refresh-client -f` | All | Helvesec/rmux#251 (closes #243) |

Update this table when you add, change or retire a fix.

## Patch rules

- **Minimal**: change only the lines that fix the problem. Match upstream
  style: Conventional Commit subjects (`fix(<area>): <what>`), `cargo fmt`,
  clippy clean with `-D warnings`.
- **Isolated**: each fix branch starts at `<fork-point>` and changes no file
  another fix changes. Two fixes that share a file become one fix.
- **Curated history**: a fix branch reads as a patch series for an upstream
  reviewer. Each commit is one reviewable step that builds and passes its
  tests. The body gives the cause, then the change, then the platform it was
  tested on (CONTRIBUTING.md asks for it). Every commit carries a
  `Signed-off-by:` line (`git commit -s`; RMUX's DCO).
- **Present tense**: the series describes the fix against the current `<tag>`.
  Fold corrections into the commit they correct:
  `git commit --fixup=<commit>`, then
  `git -c sequence.editor=: rebase -i --autosquash <fork-point>`.
- **Red first**: the fix's test fails at `<fork-point>` and passes with the
  fix. Where a test cannot fail at the fork point (it calls a function the fix
  adds) or needs a binary too large to build twice, the commit names the probe
  that shows the old behaviour.

## RMUX specifics

- **Three binaries ship together.** `rmux.exe` is a small dispatcher (feature
  `tiny-cli`) that runs `libexec/rmux/rmux.exe`, the full CLI, which is also the
  daemon (`--__internal-daemon`); `rmux-daemon.exe` is the standalone daemon.
  Build them with `scripts/package-windows.ps1`, never one by hand, and install
  them as one folder. A caller that needs the name `tmux` gets a copy of the
  full helper (`Build-PatchSet.ps1 -TmuxName`); RMUX's own `rmux claude` does
  the same.
- **Toolchain.** `rust-toolchain.toml` pins the compiler. If that toolchain is
  not installed, build with `RUSTUP_TOOLCHAIN=stable` (or `cargo +stable`) and
  say so in the pull request; do not change the pin in a fix.
- **One target directory.** A workspace build is several GB. Set
  `CARGO_TARGET_DIR` to one shared directory for every worktree; cargo locks it,
  so builds run one at a time. The package build uses its own target triple
  directory (`target/x86_64-pc-windows-msvc`) and a static CRT, so it does not
  reuse a plain `cargo build`.
- **Large test binaries.** `rmux-server`'s unit-test binary holds about 4,000
  tests. On a small machine build it with `--release -j 2` and
  `CARGO_PROFILE_RELEASE_DEBUG=0`, then run single modules by filter.
- **Unsafe code.** `rmux-server` and `rmux-core` are `#![forbid(unsafe_code)]`.
  Windows API calls live in `rmux-os`, `rmux-pty` and `rmux-ipc`, and every
  `unsafe` block there needs a `SAFETY:` comment within a few lines
  (`scripts/unsafe-check.sh`).
- **Platform code.** Keep Windows-only behaviour behind `#[cfg(windows)]` in the
  platform crates or a `cfg` arm, mark Windows-only tests `#[cfg(windows)]`, and
  run `scripts/check-platform-neutrality.sh` for shared crates. CI runs
  `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets
  --locked -- -D warnings`, and `cargo test --locked` per package.

## Update and push

Run `pwsh .worktrees/patch-maintenance/Update-PatchSet.ps1 -Tag <tag>` after
every change to a fix. It rebases, checks and pushes the whole set in one
all-or-nothing run, and prints `merged=<commit>`; `Get-Help <script> -Full`
describes each step. When a run fails, every fix is back where it started:

- **A fix does not rebase**: in its worktree, run the `git rebase --onto`
  command the script prints, resolve the conflicts, and curate the series.
- **A fix has no commits left**: upstream has it. [Retire the fix](#retire-a-fix).
- **Fixes share a file**: combine them into one fix, or change them so each
  touches its own files.
- **A fix does not merge onto the tag**: make the fix apply to both.

## Build and install

`pwsh .worktrees/patch-maintenance/Build-PatchSet.ps1 -Merged <commit> -InstallRoot <dir>`
packages `<commit>` (the `merged=` value) with RMUX's own packaging script,
installs it in a new folder under `<dir>`, and points `<dir>/current` at it.
Add `-Toolchain stable` when the pinned toolchain is missing and `-TmuxName` for
a `tmux.exe`. Add `-KeepCurrent` to try a build from its own folder before
`current` moves to it. Older folders stay, so servers that run from them keep
working.

## Add a fix

1. Create the branch at the fork point, in its worktree:
   `git worktree add -b fix/<fix> .worktrees/xanth/fix/<fix> $(git merge-base <tag> origin/main)`
2. Write the test, then confirm it goes red at `<fork-point>`.
3. Make the fix, confirm the test passes, run the module's tests, `cargo fmt`
   and clippy, then commit with `git commit -s`.
4. Add the fix to [Series](#series), then [update and push](#update-and-push).

## Move to a new tag

1. [Update and push](#update-and-push) with `-Tag <new-tag>`, and run it again
   after each fix by hand until it finishes without an error.
2. Curate every fix against the new fork point and run its tests. If any fix
   changed, update and push again, then [build and install](#build-and-install).

## Retire a fix

When upstream makes a fix unnecessary, delete it everywhere:

1. `git worktree remove .worktrees/xanth/fix/<fix>`
2. `git branch -D fix/<fix>`
3. `git push xanth --delete fix/<fix>`
4. Remove its row from [Series](#series).

## Keep this file

This branch is public. This file and the scripts hold only the shared layout
and patch set maintenance. Machine setup and install paths go in the private
root `AGENTS.local.md`. No machine names, user paths or secrets.

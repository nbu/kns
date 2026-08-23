# kns consistency cleanup — design

Date: 2026-08-22

## Problem

An audit of the kns repo found documentation/code mismatches, correctness bugs (especially under zsh), duplicated merge logic, and ambiguous product wording. This design defines a single cleanup to make behavior consistent, documented, and maintainable.

## Goals

- Fix real correctness bugs so bash and zsh behave as documented.
- Align README and `kns help` with actual behavior.
- Deduplicate config-merge logic and remove dead code.
- Improve shell integration using mise-style hooks.
- Keep the install UX unchanged (PATH + `source kns.sh`).

## Non-goals

- Replace `source` of `.kns.conf` with a safe parser (document a security warning only).
- Extract a shared `kns-lib.sh` for CLI and shell hook.
- Add an explicit “clear namespace” CLI.
- Change `kns unlink` or `kns use` product behavior (documentation only).
- Add an automated test framework.
- Share one physical library file between `kns` and `kns.sh` (same merge *rules*, separate implementations).

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| Scope | Full cleanup in one PR |
| `.kns.conf` loading | Keep `source`; add security warning in README |
| `kns unlink` | Delete whole `$PWD/.kns.conf`; docs say so |
| Shell hooks | zsh: `chpwd`; bash: wrap `cd` / `pushd` / `popd` |
| `kns set <context>` (no namespace) | Omit `KNS_NAMESPACE` from the file (do not write empty) |
| `kns use` override | Keep current behavior; document clearly |
| Install rc lines | Keep PATH + `source kns.sh`; make PATH append idempotent |

## Architecture

### Components

- **`kns`** — CLI script (`#!/usr/bin/env bash`). Context/namespace/pod commands, kubectl shortcuts, writes `.kns.conf`, applies kubectl.
- **`kns.sh`** — Sourced into the interactive shell. Directory-change hook merges configs and switches context/namespace; clears manual override on directory change.
- **`install.sh` / `install-standalone.sh`** — Install files to `INSTALL_DIR`, ensure PATH and `source kns.sh` in the detected shell rc.

### Config merge rules (single ruleset)

Same rules in `kns` and `kns.sh` (implemented separately in each file — no shared lib):

1. Walk from `$PWD` up to `/`, collecting every `.kns.conf`.
2. If `$HOME/.kns.conf` exists and is **not** already in the list, append it (avoids double-count when `$HOME` is an ancestor of `$PWD`).
3. Source files from farthest parent to closest child so child values win.
4. When **writing** config (`kns set`, etc.), omit keys that are unset/empty rather than writing `KEY=""`, so a fresh `kns set <context>` without a namespace cannot wipe a parent namespace via merge.

### Shell integration

- **zsh:** `autoload -U add-zsh-hook` then `add-zsh-hook chpwd <apply_fn>`. No `cd` alias.
- **bash:** Wrap `cd`, `pushd`, and `popd` to call the same apply function after a successful directory change.
- Detect shell at source time (`zsh` vs `bash`); use shell-appropriate arrays/indexing so zsh does not break parent→child merge.
- On directory change: clear `$KNS_CONFIG_DIR/manual_override` (default `~/.kns/manual_override`), then merge and apply context/namespace if `KNS_CONTEXT` is set.
- Respect existing `KNS_QUIET` and `KNS_DEBUG`.

### Manual override

- `kns use` writes override file under `KNS_CONFIG_DIR`.
- While present, CLI auto-switch and `kns current` prefer the override.
- Directory-change hook removes the override so `.kns.conf` applies again.
- No behavior change; documentation must describe this lifecycle.

### Dead code / cleanup in `kns`

- Remove unused `KNS_CONFIG_FILE` (never read/written).
- Consolidate duplicated walk/source blocks into one internal merge helper used by `current`, `auto_switch_context`, pod helpers, etc.
- Delete unused helpers (`find_context_file`, `source_all_context_files`, `read_context`) once a single internal merge helper exists inside `kns`.
- Document `KNS_CONFIG_DIR` as storage for manual override (not a general “global config” store).

## Behavior changes

### `kns set <context>` without namespace

- Write `KNS_CONTEXT` only.
- Do not write `KNS_NAMESPACE=""`.
- Preserve existing local pod/container fields as today.
- Still invoke context switch via `cmd_use`; only set kubectl namespace when a namespace argument was provided.

### `kns unlink`

- Unchanged: `rm` `$PWD/.kns.conf`.
- Docs/help: removes the local kns config file (context, namespace, pod, container).

### Installers

- Before appending a PATH export, check whether the rc already contains an equivalent kns PATH line (mirror the existing `kns.sh` grep guard).
- Still append `source $INSTALL_DIR/kns.sh` only when missing.
- Do not change the requirement that users open a new shell or `source` their rc after install.

### README / help

- Fix Quick Install: real clone URL `https://github.com/nbu/kns`, `cd kns` (not `cd k`).
- Document why `source kns.sh` is required for auto-switch (PATH alone is CLI-only).
- Security: warn that `.kns.conf` is sourced as shell code; only use trusted directories.
- Document `~/.kns.conf`, merge rules, mise-style hooks, `kns use` override until directory change, `unlink` deleting the whole file, `KNS_CONFIG_DIR` purpose.
- Minor: drop duplicate `.DS_Store` entry in `.gitignore` if touched.

## Error handling

- Missing/invalid kubectl context: CLI commands keep failing with clear errors; silent failure on hook switch remains acceptable when context is invalid (no successful “Switched” message).
- Bad `.kns.conf`: keep `source … || true` so the interactive shell is not aborted; risk covered by the security/trust warning.
- No config files: hook no-ops; `kns current` exits non-zero with existing messaging.
- zsh hook setup failure: attempt standard `autoload` of `add-zsh-hook`; on failure print one warning line to stderr.

## Testing (manual)

No test harness in-repo. Checklist before merge:

1. **bash:** `cd`, `pushd`, `popd` each apply merged config; override cleared on directory change.
2. **zsh:** `chpwd` fires for `cd` / `pushd` / `popd` and applies merge.
3. Parent + child `.kns.conf` merge; home file applied once when under `$HOME`.
4. `kns set my-ctx` does not write empty namespace; parent namespace still merges.
5. Re-run installer: single PATH line, single `source kns.sh` line.
6. `unlink` / `use` / `current` output matches updated docs.

## Rollout

- One PR implementing this design.
- No migration step: newly written files omit empty namespace; existing `KNS_NAMESPACE=""` lines remain until the user runs `set` again (or edits the file).

## Success criteria

- Documented install, merge, hooks, `use`, and `unlink` match code.
- zsh users get reliable parent/child merge on directory change.
- Reinstall does not spam PATH lines.
- Dead merge duplication and unused config path are gone from `kns`.

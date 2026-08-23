# kns Consistency Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make kns docs match behavior, fix zsh/merge/installer bugs, and clean dead duplication — without changing unlink/use product semantics or adding a shared library.

**Architecture:** Keep `kns` (bash CLI) and `kns.sh` (sourced shell hook) separate with the same merge *rules* but separate implementations. Rewrite hooks to mise-style (zsh `chpwd`, bash `cd`/`pushd`/`popd`). Consolidate merge/write helpers inside `kns` only.

**Tech Stack:** bash, zsh, kubectl, POSIX-ish install scripts, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-22-consistency-cleanup-design.md`

## Global Constraints

- Keep `source` of `.kns.conf` (README security warning only — no safe parser).
- Do not extract `kns-lib.sh`.
- Do not change `unlink` or `use` product behavior (docs only).
- No new automated test framework — verify with the exact commands in each task.
- Install still writes PATH + `source …/kns.sh`; PATH append must be idempotent via rc `grep`.
- `kns set <context>` with no namespace must omit `KNS_NAMESPACE` (never write `KNS_NAMESPACE=""`).
- Frequent commits as listed at end of each task.

## File map

| File | Role after cleanup |
|------|--------------------|
| `kns` | CLI; `_kns_collect_conf_files` + `_kns_source_merged_conf`; omit empty keys on write; delete dead helpers |
| `kns.sh` | zsh `chpwd` / bash wraps; home dedupe; clear `manual_override` on dir change |
| `install.sh` | Idempotent PATH + `source kns.sh` |
| `install-standalone.sh` | Same rc guards |
| `README.md` | Accurate clone URL, hooks, security, override, unlink, `KNS_CONFIG_DIR` |
| `.gitignore` | Single `.DS_Store` entry |

---

### Task 1: Consolidate merge helpers + home dedupe in `kns`

**Files:**
- Modify: `kns`

**Interfaces:**
- Consumes: `KNS_LOCAL_FILE`, `KNS_CONFIG_DIR` (existing)
- Produces:
  - `_kns_collect_conf_files` → fills `_kns_conf_files` (closest-first); append `$HOME/.kns.conf` only if not already listed; return 0/1
  - `_kns_source_merged_conf` → unset `KNS_CONTEXT` `KNS_NAMESPACE` `KNS_POD` `KNS_CONTAINER`, source farthest→closest; return 0/1
- Deletes: `find_context_file`, `source_all_context_files`, `read_context`, unused `KNS_CONFIG_FILE`
- Rewires: `cmd_current`, `auto_switch_context`, `cmd_get_containers`, `get_current_pod_container`
- Keeps: `read_pod_config` (still used by `cmd_set` / pod writers)

- [ ] **Step 1: Confirm home double-append baseline**

```bash
rg -n 'files\+=\("\$HOME/\$KNS_LOCAL_FILE"\)' kns
```

Expected: multiple matches (unconditional append after walk).

- [ ] **Step 2: Update config header; add helpers; delete dead functions**

Replace the top config block with:

```bash
# Configuration
KNS_CONFIG_DIR="${KNS_CONFIG_DIR:-$HOME/.kns}"
KNS_LOCAL_FILE=".kns.conf"

# Ensure config directory exists
mkdir -p "$KNS_CONFIG_DIR"
```

Delete entire functions `find_context_file`, `source_all_context_files`, and `read_context`.

Insert after `main()`:

```bash
# Closest-first .kns.conf paths. Home file only if not already in the walk.
# Sets global array _kns_conf_files.
_kns_collect_conf_files() {
  _kns_conf_files=()
  local dir="$PWD"
  local f
  local home_file="$HOME/$KNS_LOCAL_FILE"

  while [[ "$dir" != "/" ]]; do
    f="$dir/$KNS_LOCAL_FILE"
    if [[ -f "$f" ]]; then
      _kns_conf_files+=("$f")
    fi
    dir=$(dirname "$dir")
  done

  if [[ -f "$home_file" ]]; then
    local already=0
    local existing
    for existing in "${_kns_conf_files[@]+"${_kns_conf_files[@]}"}"; do
      if [[ "$existing" == "$home_file" ]]; then
        already=1
        break
      fi
    done
    if [[ $already -eq 0 ]]; then
      _kns_conf_files+=("$home_file")
    fi
  fi

  [[ ${#_kns_conf_files[@]} -gt 0 ]]
}

# Unset kns vars; source collected files farthest → closest (child wins).
_kns_source_merged_conf() {
  unset KNS_CONTEXT KNS_NAMESPACE KNS_POD KNS_CONTAINER
  if ! _kns_collect_conf_files; then
    return 1
  fi
  local i
  for ((i = ${#_kns_conf_files[@]} - 1; i >= 0; i--)); do
    if [[ -f "${_kns_conf_files[i]}" ]]; then
      # shellcheck disable=SC1090
      source "${_kns_conf_files[i]}" 2>/dev/null || true
    fi
  done
  return 0
}
```

- [ ] **Step 3: Rewire callers**

**`cmd_current`:** After the manual-override early return, replace the duplicated walk/source/display block with:

```bash
  if ! _kns_source_merged_conf; then
    echo "No .kns.conf file found in current or parent directories"
    exit 1
  fi

  if [[ ${#_kns_conf_files[@]} -gt 1 ]]; then
    echo "Source: ${_kns_conf_files[*]} (merged)"
  else
    echo "Source: ${_kns_conf_files[0]}"
  fi

  if [[ -n "${KNS_CONTEXT:-}" ]]; then
    echo "Context: $KNS_CONTEXT"
  else
    echo "Context: <not set>"
  fi
  if [[ -n "${KNS_NAMESPACE:-}" ]]; then
    echo "Namespace: $KNS_NAMESPACE"
  fi
  if [[ -n "${KNS_POD:-}" ]]; then
    echo "Pod: $KNS_POD"
  fi
  if [[ -n "${KNS_CONTAINER:-}" ]]; then
    echo "Container: $KNS_CONTAINER"
  fi
```

Keep the existing manual-override branch text exactly (`Source: Manual override (from 'kns use' command)`, etc.).

**`auto_switch_context`:** After manual-override handling, replace walk/source/apply by calling `_kns_source_merged_conf`, then reuse the **exact** `kubectl config use-context` / `kubectl config set-context … --namespace=` lines already present in that function (do not invent new kubectl flags).

**`cmd_get_containers` and `get_current_pod_container`:** Replace their walk/source loops with `_kns_source_merged_conf`; keep all kubectl / error messaging unchanged.

- [ ] **Step 4: Syntax check + merge smoke**

```bash
bash -n kns
REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP=$(mktemp -d)
mkdir -p "$TMP/project/app"
printf '%s\n' 'KNS_CONTEXT="parent-ctx"' 'KNS_NAMESPACE="parent-ns"' > "$TMP/project/.kns.conf"
printf '%s\n' 'KNS_POD="child-pod"' > "$TMP/project/app/.kns.conf"
cd "$TMP/project/app"
PATH="$REPO_ROOT:$PATH" kns current
rm -rf "$TMP"
```

Expected: Source lists both files (merged); Context `parent-ctx`; Namespace `parent-ns`; Pod `child-pod`.

- [ ] **Step 5: Commit**

```bash
git add kns
git commit -m "$(cat <<'EOF'
Refactor kns config merge into helpers with home dedupe.

EOF
)"
```

---

### Task 2: Omit empty `KNS_NAMESPACE` on `kns set`

**Files:**
- Modify: `kns` (`cmd_set`)

**Interfaces:**
- Consumes: `read_pod_config`, `cmd_use`
- Produces: `.kns.conf` without `KNS_NAMESPACE` line when namespace arg empty

- [ ] **Step 1: Show current write always emits namespace**

```bash
rg -n 'KNS_NAMESPACE="\$namespace"' kns
```

Expected: match inside `cmd_set` heredoc.

- [ ] **Step 2: Change `cmd_set` write block**

Replace the `cat > "$file" <<EOF ... EOF` plus trailing pod appends with:

```bash
  {
    echo "# Auto-generated by kns"
    echo "KNS_CONTEXT=\"$context\""
    if [[ -n "$namespace" ]]; then
      echo "KNS_NAMESPACE=\"$namespace\""
    fi
    if [[ -n "$existing_pod" ]]; then
      echo "KNS_POD=\"$existing_pod\""
    fi
    if [[ -n "$existing_container" ]]; then
      echo "KNS_CONTAINER=\"$existing_container\""
    fi
  } > "$file"
```

Keep the user-facing echoes and `cmd_use "$context" "$namespace"` call (empty namespace already means `cmd_use` does not set namespace).

- [ ] **Step 3: Verify omit + parent merge**

```bash
bash -n kns
TMP=$(mktemp -d)
mkdir -p "$TMP/parent/child"
printf '%s\n' 'KNS_CONTEXT="c"' 'KNS_NAMESPACE="ns-from-parent"' > "$TMP/parent/.kns.conf"
# Simulate set-without-namespace write in child:
context=c
namespace=
{
  echo "# Auto-generated by kns"
  echo "KNS_CONTEXT=\"$context\""
  if [[ -n "$namespace" ]]; then
    echo "KNS_NAMESPACE=\"$namespace\""
  fi
} > "$TMP/parent/child/.kns.conf"
grep KNS_NAMESPACE "$TMP/parent/child/.kns.conf" && echo FAIL || echo PASS
cd "$TMP/parent/child"
PATH="/Users/borys/dev/github/nbu/kns:$PATH" kns current
rm -rf "$TMP"
```

Expected: `PASS`; `kns current` shows Namespace `ns-from-parent`.

- [ ] **Step 4: Commit**

```bash
git add kns
git commit -m "$(cat <<'EOF'
Omit empty KNS_NAMESPACE when kns set has no namespace argument.

EOF
)"
```

---

### Task 3: Rewrite `kns.sh` (mise-style hooks + zsh-safe merge)

**Files:**
- Modify: `kns.sh` (replace hook strategy; keep `KNS_QUIET` / `KNS_DEBUG` / override clear)

**Interfaces:**
- Consumes: `.kns.conf` merge rules; `KNS_CONFIG_DIR`, `KNS_QUIET`, `KNS_DEBUG`
- Produces: `kns_apply_dir_context`; zsh `chpwd` hook; bash aliases for `cd`/`pushd`/`popd`
- Clears: `$KNS_CONFIG_DIR/manual_override` (default `~/.kns/manual_override`) on every directory change

- [ ] **Step 1: Replace `kns.sh` with the following**

```bash
# kns.sh - Shell integration for automatic context switching
# Source from .bashrc / .zshrc (installers append this).

kns_collect_conf_files() {
  # Closest-first paths in kns_conf_files. Home only if not already listed.
  kns_conf_files=()
  local dir="$PWD"
  local f
  local home_file="$HOME/.kns.conf"

  while [[ "$dir" != "/" ]]; do
    f="$dir/.kns.conf"
    if [[ -f "$f" ]]; then
      kns_conf_files+=("$f")
    fi
    dir=$(dirname "$dir")
  done

  if [[ -f "$home_file" ]]; then
    local already=0
    local existing
    for existing in ${kns_conf_files[@]+"${kns_conf_files[@]}"}; do
      if [[ "$existing" == "$home_file" ]]; then
        already=1
        break
      fi
    done
    if [[ $already -eq 0 ]]; then
      kns_conf_files+=("$home_file")
    fi
  fi

  [[ ${#kns_conf_files[@]} -gt 0 ]]
}

kns_apply_dir_context() {
  local KNS_CONTEXT="" KNS_NAMESPACE="" KNS_POD="" KNS_CONTAINER=""
  local kns_conf_files
  kns_conf_files=()

  if [[ "${KNS_DEBUG:-}" == "1" ]]; then
    if kns_collect_conf_files; then
      echo "[kns] Found config files: ${kns_conf_files[*]}" >&2
    else
      echo "[kns] No config file found" >&2
    fi
  fi

  local manual_override_file="${KNS_CONFIG_DIR:-$HOME/.kns}/manual_override"
  if [[ -f "$manual_override_file" ]]; then
    rm -f "$manual_override_file"
  fi

  unset KNS_CONTEXT KNS_NAMESPACE KNS_POD KNS_CONTAINER
  kns_conf_files=()
  if ! kns_collect_conf_files; then
    return 0
  fi

  # Farthest-first via prepend (bash 0-based and zsh 1-based safe).
  local reverse=()
  local f
  for f in ${kns_conf_files[@]+"${kns_conf_files[@]}"}; do
    reverse=("$f" ${reverse[@]+"${reverse[@]}"})
  done
  for f in ${reverse[@]+"${reverse[@]}"}; do
    # shellcheck disable=SC1090
    source "$f" 2>/dev/null || true
  done

  if [[ -z "${KNS_CONTEXT:-}" ]]; then
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    return 0
  fi

  local current_context=""
  current_context=$(kubectl config current-context 2>/dev/null || echo "")
  local current_namespace=""
  current_namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "")

  local needs_switch=0
  if [[ "$current_context" != "$KNS_CONTEXT" ]]; then
    needs_switch=1
  elif [[ -n "${KNS_NAMESPACE:-}" && "$current_namespace" != "$KNS_NAMESPACE" ]]; then
    needs_switch=1
  fi

  if [[ $needs_switch -eq 1 ]]; then
    if kubectl config use-context "$KNS_CONTEXT" >/dev/null 2>&1; then
      if [[ -n "${KNS_NAMESPACE:-}" ]]; then
        kubectl config set-context "$KNS_CONTEXT" --namespace="$KNS_NAMESPACE" >/dev/null 2>&1
      fi
      if [[ "${KNS_QUIET:-}" != "1" ]]; then
        if [[ -n "${KNS_NAMESPACE:-}" ]]; then
          echo "✓ Switched to context: $KNS_CONTEXT (namespace: $KNS_NAMESPACE)"
        else
          echo "✓ Switched to context: $KNS_CONTEXT"
        fi
      fi
    fi
  fi
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  if ! autoload -U add-zsh-hook 2>/dev/null; then
    echo "kns: warning: could not load add-zsh-hook; auto-switch disabled" >&2
  else
    add-zsh-hook chpwd kns_apply_dir_context
  fi
elif [[ -n "${BASH_VERSION:-}" ]]; then
  kns_cd() {
    builtin cd "$@" || return
    kns_apply_dir_context
  }
  kns_pushd() {
    builtin pushd "$@" || return
    kns_apply_dir_context
  }
  kns_popd() {
    builtin popd "$@" || return
    kns_apply_dir_context
  }
  alias cd=kns_cd
  alias pushd=kns_pushd
  alias popd=kns_popd
fi

if command -v kns >/dev/null 2>&1; then
  :
elif [[ -f "$HOME/.local/bin/kns" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
```

- [ ] **Step 2: Syntax-check both shells**

```bash
bash -n kns.sh
zsh -n kns.sh
```

Expected: exit 0, no output.

- [ ] **Step 3: Hook registration smoke**

```bash
bash -c 'source ./kns.sh; alias cd; alias pushd; alias popd'
zsh -c 'source ./kns.sh; typeset -f kns_apply_dir_context >/dev/null && echo function_ok; autoload -U add-zsh-hook; add-zsh-hook -L 2>/dev/null | grep -i kns || echo "check hook list manually"'
```

Expected: bash shows aliases to `kns_cd` / `kns_pushd` / `kns_popd`; zsh defines `kns_apply_dir_context` and registers chpwd.

- [ ] **Step 4: Commit**

```bash
git add kns.sh
git commit -m "$(cat <<'EOF'
Rewrite kns.sh with zsh chpwd and bash cd/pushd/popd hooks.

EOF
)"
```

---

### Task 4: Idempotent PATH lines in installers

**Files:**
- Modify: `install.sh`
- Modify: `install-standalone.sh`

**Interfaces:**
- Consumes: `INSTALL_DIR`, detected shell rc path
- Produces: PATH export appended only if rc does not already contain `$INSTALL_DIR`

- [ ] **Step 1: Fix `install.sh`**

Replace the PATH guard that checks `:$PATH:` with an rc-file grep. Target pattern (adapt to existing variable names `INSTALL_DIR` / `SHELL_RC`):

```bash
if [[ -n "$SHELL_RC" ]] && [[ -f "$SHELL_RC" ]]; then
  if ! grep -qF "$INSTALL_DIR" "$SHELL_RC" 2>/dev/null; then
    echo "Adding $INSTALL_DIR to PATH in $SHELL_RC"
    echo "" >> "$SHELL_RC"
    echo "# kns - Kubernetes context switcher" >> "$SHELL_RC"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_RC"
  fi

  if ! grep -q "kns.sh" "$SHELL_RC" 2>/dev/null; then
    echo "Adding kns shell integration to $SHELL_RC"
    echo "" >> "$SHELL_RC"
    echo "# Source kns shell integration" >> "$SHELL_RC"
    echo "source $INSTALL_DIR/kns.sh" >> "$SHELL_RC"
  fi
fi
```

Preserve the rest of `install.sh` (copy binaries, chmod, messages).

- [ ] **Step 2: Fix `install-standalone.sh`**

Same change: decide PATH append with `grep -qF "$INSTALL_DIR" "$shell_rc"` (or whatever the local rc variable is named), not `:$PATH:`. Keep existing `kns.sh` grep guard.

- [ ] **Step 3: Verify idempotency logic**

```bash
RC=$(mktemp)
INSTALL_DIR=/tmp/kns-fake-bin
echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$RC"
if ! grep -qF "$INSTALL_DIR" "$RC" 2>/dev/null; then echo ADD; else echo SKIP; fi
# Expected: SKIP
rm -f "$RC"
rg -n 'PATH:' install.sh install-standalone.sh || echo "no live PATH-string checks left for install decision"
```

Expected: `SKIP`; no remaining `:$PATH:` guards used for the append decision (other PATH mentions in echo help text are fine).

- [ ] **Step 4: Commit**

```bash
git add install.sh install-standalone.sh
git commit -m "$(cat <<'EOF'
Make installer PATH updates idempotent based on shell rc contents.

EOF
)"
```

---

### Task 5: README, help text, `.gitignore`

**Files:**
- Modify: `README.md`
- Modify: `kns` (`show_help`)
- Modify: `.gitignore`

- [ ] **Step 1: Fix README install + behavior docs**

1. Replace Quick Install clone block:

```bash
git clone https://github.com/nbu/kns.git
cd kns
./install.sh
```

(Use the real repo URL if remote differs — check `git remote get-url origin` and use that HTTPS URL.)

2. Clarify Manual Install: PATH alone → CLI only; `source …/kns.sh` → auto-switch (zsh `chpwd`; bash `cd`/`pushd`/`popd`).

3. Add **Security**: `.kns.conf` is sourced as shell; only trust directories you control.

4. Document: `~/.kns.conf`; merge parent→child; `kns use` override until next directory change; `kns unlink` deletes the whole local `.kns.conf`; `KNS_CONFIG_DIR` stores `manual_override` only.

5. Remove any “global config file” implication for unused `config` path.

- [ ] **Step 2: Update `show_help` strings**

Align with README:
- `unlink` — remove `.kns.conf` from the current directory (all local kns settings).
- `use` — switch context now; override until next directory change.
- CONFIGURATION — mention merge / `~/.kns.conf` / `KNS_CONFIG_DIR` for override storage.

- [ ] **Step 3: Dedupe `.gitignore`**

Keep a single `.DS_Store` entry (remove duplicate).

- [ ] **Step 4: Commit**

```bash
git add README.md kns .gitignore
git commit -m "$(cat <<'EOF'
Align README and help with cleanup behavior; tidy gitignore.

EOF
)"
```

---

### Task 6: End-to-end manual verification

**Files:** none (verification only; commit only if fixes needed)

- [ ] **Step 1: Run design checklist**

1. bash: `source kns.sh`; `cd` / `pushd` / `popd` into a dir with `.kns.conf` → switch message (or quiet with `KNS_QUIET=1`).
2. zsh: same via `chpwd` (no need for `cd` alias).
3. Parent+child merge via `kns current`.
4. Home file appears once in Source when `$PWD` is under `$HOME`.
5. `kns set my-ctx` → no `KNS_NAMESPACE=` line; parent namespace still merges.
6. Installer rc: PATH/`source` logic twice → one of each line.
7. `unlink` / `use` / `current` match updated docs.

- [ ] **Step 2: Fix any failures; commit if needed**

```bash
git status
# If fixes:
# git add … && git commit -m "Fix verification issues from consistency cleanup."
```

---

## Spec coverage

| Spec requirement | Task |
|------------------|------|
| zsh-safe merge / mise hooks | 3 |
| Home `.kns.conf` dedupe | 1, 3 |
| Omit empty namespace on set | 2 |
| Installer PATH idempotency | 4 |
| Dead code + merge consolidate in `kns` | 1 |
| README/help/security/use/unlink/`KNS_CONFIG_DIR` | 5 |
| Manual checklist | 6 |
| Keep `source` + install `source kns.sh` | Constraints |

## Self-review notes

- CLI helpers: `_kns_*`; shell hook: `kns_*` (no shared lib).
- Reverse merge in `kns.sh` uses array prepend (zsh-safe); `kns` CLI stays bash-only with C-style 0-based loops.
- kubectl commands must match existing repo usage: `kubectl config use-context` and `kubectl config set-context … --namespace=…`.

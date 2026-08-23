#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected '$needle' in: $haystack"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

make_kubectl() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
if [[ "$*" == "config use-context bad-context" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/bin/kubectl"
}

run_hook_leak_test() {
  local shell="$1"
  local dir="$TMP/hook-$shell"
  mkdir -p "$dir/a" "$dir/b" "$dir/c" "$dir/home" "$dir/cfg"
  make_kubectl "$dir"
  cat > "$dir/a/.kns.conf" <<'EOF'
KNS_ENVS="stage"
KNS_DEFAULT_ENV="stage"
KNS_PROMPT_ON_ENTER=0
KNS_ENV_stage_CONTEXT="context-a"
EOF
  cat > "$dir/b/.kns.conf" <<'EOF'
KNS_ENVS="stage"
KNS_DEFAULT_ENV="stage"
KNS_PROMPT_ON_ENTER=0
EOF
  cat > "$dir/c/.kns.conf" <<'EOF'
KNS_ENVS="prod"
KNS_DEFAULT_ENV="prod"
KNS_PROMPT_ON_ENTER=0
KNS_ENV_prod_CONTEXT="context-c"
EOF

  local output
  output=$(
    HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
      PATH="$dir/bin:$PATH" KNS_QUIET=1 "$shell" -c '
        source "'"$ROOT"'/kns.sh"
        if [[ -n "${ZSH_VERSION:-}" ]]; then
          add-zsh-hook -d chpwd kns_apply_dir_context
        fi
        builtin cd "'"$dir"'/a"; kns_apply_dir_context
        builtin cd "'"$dir"'/c"; kns_apply_dir_context
        builtin cd "'"$dir"'/b"; kns_apply_dir_context
      ' 2>&1
  )
  assert_contains "$output" "Environment 'stage' has no context configured"
  assert_not_exists "$dir/cfg/active_env"
  local log
  log=$(<"$dir/kubectl.log")
  [[ $(printf '%s\n' "$log" | awk '$0 == "config use-context context-a" { n++ } END { print n+0 }') -eq 1 ]] ||
    fail "$shell reused project A context; kubectl log: $log"
}

run_hook_leak_test bash
if command -v zsh >/dev/null 2>&1; then
  run_hook_leak_test zsh
fi

cli="$TMP/cli"
mkdir -p "$cli/project" "$cli/home" "$cli/cfg"
make_kubectl "$cli"
cat > "$cli/project/.kns.conf" <<'EOF'
KNS_ENVS="good bad"
KNS_DEFAULT_ENV="good"
KNS_PROMPT_ON_ENTER=0
KNS_ENV_good_CONTEXT="good-context"
KNS_ENV_good_POD="app"
KNS_ENV_bad_CONTEXT="bad-context"
KNS_ENV_bad_POD="app"
EOF

set +e
output=$(
  cd "$cli/project"
  HOME="$cli/home" KNS_CONFIG_DIR="$cli/cfg" KUBECTL_LOG="$cli/kubectl.log" \
    PATH="$cli/bin:$PATH" "$ROOT/kns" env bad 2>&1
)
status=$?
set -e
[[ $status -ne 0 ]] || fail "failed context unexpectedly succeeded"
assert_not_exists "$cli/cfg/active_env"

cat > "$cli/cfg/active_env" <<EOF
KNS_SESSION_ROOT="$cli/project"
KNS_SESSION_ENV="removed"
EOF

set +e
output=$(
  cd "$cli/project"
  HOME="$cli/home" KNS_CONFIG_DIR="$cli/cfg" KUBECTL_LOG="$cli/kubectl.log" \
    PATH="$cli/bin:$PATH" "$ROOT/kns" exec true 2>&1
)
status=$?
set -e
[[ $status -ne 0 ]] || fail "mutating command used ambient kubectl context"
assert_contains "$output" "kns env"

: > "$cli/kubectl.log"
output=$(
  cd "$cli/project"
  HOME="$cli/home" KNS_CONFIG_DIR="$cli/cfg" KUBECTL_LOG="$cli/kubectl.log" \
    PATH="$cli/bin:$PATH" "$ROOT/kns" pods 2>&1
)
assert_contains "$output" "kns env"
assert_contains "$(<"$cli/kubectl.log")" "get pods"

single="$TMP/single"
mkdir -p "$single/project" "$single/home" "$single/cfg"
set +e
output=$(
  cd "$single/project"
  HOME="$single/home" KNS_CONFIG_DIR="$single/cfg" "$ROOT/kns" env prompt off 2>&1
)
status=$?
set -e
[[ $status -ne 0 ]] || fail "project prompt write succeeded outside multi-env"
assert_not_exists "$single/project/.kns.conf"

echo "multi-env review regressions: PASS"

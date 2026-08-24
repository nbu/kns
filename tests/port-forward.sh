#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
KNS="$ROOT/kns"
fail() { echo "FAIL: $*" >&2; exit 1; }

make_kubectl() {
  mkdir -p "$1/bin"
  cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
case "$*" in
  "get svc my-api"|"get service my-api"|"get services my-api") exit 0 ;;
  get\ svc\ *|get\ service\ *|get\ services\ *) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$1/bin/kubectl"
}

test_service_set_single() {
  local dir="$TMP/svc-single"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_NAMESPACE="ns"
EOF
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' service set my-api"
  grep -q 'KNS_SERVICE="my-api"' "$dir/proj/.kns.conf" || fail "service not written"
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' service unset"
  grep -q KNS_SERVICE "$dir/proj/.kns.conf" && fail "service should be removed" || true
}

test_service_set_multi() {
  local dir="$TMP/svc-multi"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_ENVS="stage prod"
KNS_DEFAULT_ENV="stage"
KNS_ENV_stage_CONTEXT="stage-ctx"
KNS_ENV_prod_CONTEXT="prod-ctx"
EOF
  cat > "$dir/cfg/active_env" <<EOF
KNS_SESSION_ROOT="$dir/proj"
KNS_SESSION_ENV="stage"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' service set my-api"
  grep -q 'KNS_ENV_stage_SERVICE="my-api"' "$dir/proj/.kns.conf" ||
    fail "multi-env service not written with active env prefix"
  grep -q '^KNS_SERVICE=' "$dir/proj/.kns.conf" &&
    fail "multi-env service should not write flat key"

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' service unset"
  grep -q KNS_ENV_stage_SERVICE "$dir/proj/.kns.conf" &&
    fail "multi-env service should be removed" || true
}

test_service_multi_rejects_no_session() {
  local dir="$TMP/svc-no-session"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_ENVS="stage"
KNS_DEFAULT_ENV="stage"
KNS_ENV_stage_CONTEXT="stage-ctx"
EOF

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' service set my-api" \
    >"$dir/output" 2>&1; then
    fail "multi-env service set without session should fail"
  fi
  grep -q "select an environment first" "$dir/output" ||
    fail "missing no-session error"
  grep -q KNS_ENV_stage_SERVICE "$dir/proj/.kns.conf" &&
    fail "no-session service set changed config" || true
}

test_service_multi_rejects_stale_session() {
  local dir="$TMP/svc-stale-session"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_ENVS="stage"
KNS_DEFAULT_ENV="stage"
KNS_ENV_stage_CONTEXT="stage-ctx"
KNS_ENV_removed_SERVICE="old-api"
EOF
  cat > "$dir/cfg/active_env" <<EOF
KNS_SESSION_ROOT="$dir/proj"
KNS_SESSION_ENV="removed"
EOF

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' service set my-api" \
    >"$dir/set-output" 2>&1; then
    fail "multi-env service set with stale session should fail"
  fi
  grep -q 'KNS_ENV_removed_SERVICE="old-api"' "$dir/proj/.kns.conf" ||
    fail "stale-session service set changed config"

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' service unset" \
    >"$dir/unset-output" 2>&1; then
    fail "multi-env service unset with stale session should fail"
  fi
  grep -q 'KNS_ENV_removed_SERVICE="old-api"' "$dir/proj/.kns.conf" ||
    fail "stale-session service unset changed config"
}

test_pf_set_unset_single() {
  local dir="$TMP/pf-set"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj" "$dir/bin"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
EOF
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf set app 8080:8080 svc/my-api"
  grep -q 'KNS_FORWARD_app="8080:8080"' "$dir/proj/.kns.conf" || fail "ports missing"
  grep -q 'KNS_FORWARD_app_TARGET="svc/my-api"' "$dir/proj/.kns.conf" || fail "target missing"
  grep -q 'KNS_FORWARDS=.*app' "$dir/proj/.kns.conf" || fail "FORWARDS list missing"
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf unset app"
  grep -q KNS_FORWARD_app "$dir/proj/.kns.conf" && fail "forward keys remain" || true
}

test_pf_rejects_reserved_names() {
  local dir="$TMP/pf-reserved"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj" "$dir/bin"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
EOF
  for name in DEFAULT foo_TARGET; do
    if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
      bash -c "cd '$dir/proj' && '$KNS' pf set $name 8080:8080 svc/my-api" \
      >"$dir/output-$name" 2>&1; then
      fail "pf set $name should fail"
    fi
    grep -q KNS_FORWARD "$dir/proj/.kns.conf" &&
      fail "pf set $name should not write forward keys" || true
  done
}

test_service_set_single
test_service_set_multi
test_service_multi_rejects_no_session
test_service_multi_rejects_stale_session
test_pf_set_unset_single
test_pf_rejects_reserved_names
echo "OK (partial — more tests added in later tasks)"

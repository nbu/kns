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

test_pf_foreground_pod() {
  local dir="$TMP/pf-fg-pod"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_NAMESPACE="ns"
KNS_POD="web-0"
KNS_CONTAINER="web"
KNS_FORWARDS="app"
KNS_FORWARD_DEFAULT="app"
KNS_FORWARD_app="8080:8080"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf app"
  grep -q '^port-forward -n ns pod/web-0 8080:8080$' "$dir/kubectl.log" ||
    fail "expected foreground port-forward to pinned pod"
  grep -q 'port-forward.* -c ' "$dir/kubectl.log" &&
    fail "port-forward must not pass a container" || true
}

test_pf_foreground_explicit_service() {
  local dir="$TMP/pf-fg-explicit"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_NAMESPACE="ns"
KNS_POD="web-0"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf 9090:80 svc/my-api"
  grep -q '^port-forward -n ns svc/my-api 9090:80$' "$dir/kubectl.log" ||
    fail "explicit service target should override pinned pod"
}

test_pf_foreground_mapping_target() {
  local dir="$TMP/pf-fg-mapping-target"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_POD="web-0"
KNS_FORWARDS="api"
KNS_FORWARD_api="8080:80"
KNS_FORWARD_api_TARGET="deploy/api"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf api"
  grep -q '^port-forward deploy/api 8080:80$' "$dir/kubectl.log" ||
    fail "mapping target should override pinned pod"
}

test_pf_foreground_default_service() {
  local dir="$TMP/pf-fg-default-service"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_SERVICE="my-api"
KNS_FORWARDS="api"
KNS_FORWARD_DEFAULT="api"
KNS_FORWARD_api="8080:80"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf"
  grep -q '^port-forward svc/my-api 8080:80$' "$dir/kubectl.log" ||
    fail "bare pf should use default mapping and pinned service"
}

test_pf_foreground_requires_ports() {
  local dir="$TMP/pf-fg-no-ports"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_POD="web-0"
EOF

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf" \
    >"$dir/output" 2>&1; then
    fail "pf without ports or default mapping should fail"
  fi
  grep -q 'kns pf set' "$dir/output" || fail "missing pf set hint"
}

test_pf_foreground_requires_target() {
  local dir="$TMP/pf-fg-no-target"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
EOF

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf 8080:80" \
    >"$dir/output" 2>&1; then
    fail "pf without a target pin should fail"
  fi
  grep -q 'pod set' "$dir/output" || fail "missing pod set hint"
  grep -q 'service set' "$dir/output" || fail "missing service set hint"
}

wait_for_dead() {
  local pid="$1"
  local attempts=20
  while kill -0 "$pid" 2>/dev/null && [[ $attempts -gt 0 ]]; do
    sleep 0.05
    attempts=$((attempts - 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

make_sleeping_kubectl() {
  mkdir -p "$1/bin"
  cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "port-forward" ]]; then
  exec sleep 120
fi
exit 0
EOF
  chmod +x "$1/bin/kubectl"
}

test_pf_bg_lifecycle() {
  local dir="$TMP/pf-bg"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj" "$dir/bin"
  cat > "$dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
if [[ "$1" == "port-forward" ]]; then
  echo "$$" > "$KUBECTL_PF_PIDFILE"
  exec sleep 120
fi
exit 0
EOF
  chmod +x "$dir/bin/kubectl"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_NAMESPACE="ns"
KNS_POD="web-0"
KNS_FORWARDS="app"
KNS_FORWARD_app="18080:8080"
EOF
  export KUBECTL_PF_PIDFILE="$dir/pf.pid"

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf start app"

  local record pid
  record=$(printf '%s\n' "$dir/cfg"/pf/*.env)
  [[ -f "$record" ]] || fail "background record missing"
  # shellcheck disable=SC1090
  source "$record"
  pid="$KNS_PF_PID"
  [[ "$KNS_PF_ROOT" == "$dir/proj" ]] || fail "record has wrong project root"
  [[ "$KNS_PF_NAME" == "app" ]] || fail "record has wrong mapping name"
  [[ "$KNS_PF_PORTS" == "18080:8080" ]] || fail "record has wrong ports"
  [[ "$KNS_PF_TARGET" == "pod/web-0" ]] || fail "record has wrong target"
  kill -0 "$pid" 2>/dev/null || fail "background process is not live"

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf list" > "$dir/list"
  grep -q app "$dir/list" || fail "list missing mapping name"
  grep -q 18080:8080 "$dir/list" || fail "list missing ports"

  if HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" KUBECTL_LOG="$dir/kubectl.log" \
    PATH="$dir/bin:$PATH" bash -c "cd '$dir/proj' && '$KNS' pf start 18080:9090" \
    >"$dir/duplicate" 2>&1; then
    fail "duplicate local port should fail"
  fi
  grep -q "18080" "$dir/duplicate" || fail "duplicate error missing local port"
  [[ $(printf '%s\n' "$dir/cfg"/pf/*.env | wc -l | tr -d ' ') == 1 ]] ||
    fail "duplicate start wrote another record"

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf stop app"
  [[ ! -e "$record" ]] || fail "stop did not remove record"
  wait_for_dead "$pid" || fail "stop did not terminate process"
}

test_pf_bg_cleans_stale_records() {
  local dir="$TMP/pf-stale"
  mkdir -p "$dir/home" "$dir/cfg/pf" "$dir/proj"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_POD="web-0"
EOF
  cat > "$dir/cfg/pf/stale-list.env" <<EOF
KNS_PF_ID="stale-list"
KNS_PF_PID="999999"
KNS_PF_ROOT="$dir/proj"
KNS_PF_ENV=""
KNS_PF_NAME="app"
KNS_PF_PORTS="18080:8080"
KNS_PF_TARGET="pod/web-0"
KNS_PF_CONTEXT="ctx"
KNS_PF_NAMESPACE=""
KNS_PF_STARTED="0"
KNS_PF_LOG="$dir/cfg/pf/stale-list.log"
EOF

  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' pf list" > "$dir/list"
  [[ ! -e "$dir/cfg/pf/stale-list.env" ]] || fail "list did not clean stale record"

  cat > "$dir/cfg/pf/stale-stop.env" <<EOF
KNS_PF_ID="stale-stop"
KNS_PF_PID="999999"
KNS_PF_ROOT="$dir/proj"
KNS_PF_ENV=""
KNS_PF_NAME="app"
KNS_PF_PORTS="18080:8080"
KNS_PF_TARGET="pod/web-0"
KNS_PF_CONTEXT="ctx"
KNS_PF_NAMESPACE=""
KNS_PF_STARTED="0"
KNS_PF_LOG="$dir/cfg/pf/stale-stop.log"
EOF
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' pf stop stale-stop"
  [[ ! -e "$dir/cfg/pf/stale-stop.env" ]] || fail "stop did not clean stale record"
}

test_pf_leave_stops() {
  local dir="$TMP/pf-leave"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj" "$dir/outside"
  make_sleeping_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_POD="web-0"
EOF

  local record pid
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$ROOT:$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf start 18080:8080"
  record=$(printf '%s\n' "$dir/cfg"/pf/*.env)
  # shellcheck disable=SC1090
  source "$record"
  pid="$KNS_PF_PID"
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$ROOT:$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && source '$ROOT/kns.sh' && builtin cd '$dir/outside' && kns_apply_dir_context"
  if [[ -e "$record" ]] || ! wait_for_dead "$pid"; then
    kill "$pid" 2>/dev/null || true
    rm -f "$record"
    fail "leaving project did not stop background port-forward"
  fi
}

test_pf_env_switch_stops() {
  local dir="$TMP/pf-env-switch"
  mkdir -p "$dir/home" "$dir/cfg" "$dir/proj"
  make_sleeping_kubectl "$dir"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_ENVS="stage prod"
KNS_DEFAULT_ENV="stage"
KNS_ENV_stage_CONTEXT="stage-ctx"
KNS_ENV_stage_POD="stage-web-0"
KNS_ENV_prod_CONTEXT="prod-ctx"
KNS_ENV_prod_POD="prod-web-0"
EOF
  cat > "$dir/cfg/active_env" <<EOF
KNS_SESSION_ROOT="$dir/proj"
KNS_SESSION_ENV="stage"
EOF

  local record pid
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' pf start 18081:8080"
  record=$(printf '%s\n' "$dir/cfg"/pf/*.env)
  # shellcheck disable=SC1090
  source "$record"
  pid="$KNS_PF_PID"
  HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" PATH="$dir/bin:$PATH" \
    bash -c "cd '$dir/proj' && '$KNS' env prod"
  if [[ -e "$record" ]] || ! wait_for_dead "$pid"; then
    kill "$pid" 2>/dev/null || true
    rm -f "$record"
    fail "environment switch did not stop prior environment port-forward"
  fi
}

test_pf_completions() {
  local dir="$TMP/pf-completions"
  mkdir -p "$dir/home" "$dir/cfg/pf" "$dir/proj"
  cat > "$dir/proj/.kns.conf" <<'EOF'
KNS_CONTEXT="ctx"
KNS_FORWARDS="app metrics"
EOF
  cat > "$dir/cfg/pf/pf_test.env" <<EOF
KNS_PF_ID=pf_test
KNS_PF_PID=$$
KNS_PF_ROOT=$dir/proj
KNS_PF_ENV=
KNS_PF_NAME=app
EOF

  local out expected
  out=$(HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' __complete -- ''")
  for expected in pf service; do
    grep -qx "$expected" <<<"$out" || fail "missing top-level $expected completion"
  done

  out=$(HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' __complete -- pf ''")
  for expected in start stop list set unset app metrics; do
    grep -qx "$expected" <<<"$out" || fail "missing pf $expected completion"
  done

  out=$(HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' __complete -- pf stop ''")
  for expected in all app pf_test; do
    grep -qx "$expected" <<<"$out" || fail "missing pf stop $expected completion"
  done

  out=$(HOME="$dir/home" KNS_CONFIG_DIR="$dir/cfg" \
    bash -c "cd '$dir/proj' && '$KNS' __complete -- service ''")
  for expected in set unset; do
    grep -qx "$expected" <<<"$out" || fail "missing service $expected completion"
  done
}

test_service_set_single
test_service_set_multi
test_service_multi_rejects_no_session
test_service_multi_rejects_stale_session
test_pf_set_unset_single
test_pf_rejects_reserved_names
test_pf_foreground_pod
test_pf_foreground_explicit_service
test_pf_foreground_mapping_target
test_pf_foreground_default_service
test_pf_foreground_requires_ports
test_pf_foreground_requires_target
test_pf_bg_lifecycle
test_pf_bg_cleans_stale_records
test_pf_env_switch_stops
test_pf_leave_stops
test_pf_completions
echo "OK (partial — more tests added in later tasks)"

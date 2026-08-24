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

test_service_set_single
echo "OK (partial — more tests added in later tasks)"

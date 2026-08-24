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

kns_valid_env_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

kns_clear_env_pins() {
  local v
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    for v in ${(Mk)parameters:#KNS_ENV_*}; do
      unset "$v"
    done
  else
    for v in ${!KNS_ENV_@}; do
      unset "$v"
    done
  fi
}

kns_env_in_list() {
  local want="$1"
  local rest="${KNS_ENVS:-}"
  local env
  while [[ -n "$rest" ]]; do
    env="${rest%% *}"
    if [[ "$rest" == *" "* ]]; then
      rest="${rest#* }"
    else
      rest=""
    fi
    [[ -n "$env" ]] || continue
    [[ "$env" == "$want" ]] && return 0
  done
  return 1
}

kns_env_pins() {
  local name="$1"
  _kns_pin_ctx=""
  _kns_pin_ns=""
  _kns_pin_pod=""
  _kns_pin_container=""
  kns_valid_env_name "$name" || return 1
  eval "_kns_pin_ctx=\"\${KNS_ENV_${name}_CONTEXT-}\""
  eval "_kns_pin_ns=\"\${KNS_ENV_${name}_NAMESPACE-}\""
  eval "_kns_pin_pod=\"\${KNS_ENV_${name}_POD-}\""
  eval "_kns_pin_container=\"\${KNS_ENV_${name}_CONTAINER-}\""
  [[ -n "$_kns_pin_ctx" ]]
}

kns_envs_owner_dir() {
  local f
  local owner
  for f in ${kns_conf_files[@]+"${kns_conf_files[@]}"}; do
    owner=$(
      unset KNS_ENVS
      # shellcheck disable=SC1090
      source "$f" 2>/dev/null || true
      if [[ -n "${KNS_ENVS:-}" ]]; then
        dirname "$f"
      fi
    )
    if [[ -n "$owner" ]]; then
      echo "$owner"
      return 0
    fi
  done
  return 1
}

kns_session_file() {
  echo "${KNS_CONFIG_DIR:-$HOME/.kns}/active_env"
}

kns_session_clear() {
  rm -f "$(kns_session_file)"
}

kns_session_write() {
  local root="$1"
  local env="$2"
  local config_dir="${KNS_CONFIG_DIR:-$HOME/.kns}"
  mkdir -p "$config_dir"
  cat > "$config_dir/active_env" <<EOF
KNS_SESSION_ROOT="$root"
KNS_SESSION_ENV="$env"
EOF
}

kns_session_read() {
  _kns_session_root=""
  _kns_session_env=""
  local file
  file=$(kns_session_file)
  [[ -f "$file" ]] || return 1
  local KNS_SESSION_ROOT="" KNS_SESSION_ENV=""
  # shellcheck disable=SC1090
  source "$file" 2>/dev/null || return 1
  _kns_session_root="${KNS_SESSION_ROOT:-}"
  _kns_session_env="${KNS_SESSION_ENV:-}"
  [[ -n "$_kns_session_root" && -n "$_kns_session_env" ]]
}

kns_pwd_under_root() {
  local root="$1"
  [[ -n "$root" ]] || return 1
  [[ "$PWD" == "$root" || "$PWD" == "$root"/* ]]
}

kns_global_prompt() {
  local file="${KNS_CONFIG_DIR:-$HOME/.kns}/config"
  local line
  local value=""
  if [[ -f "$file" ]]; then
    while IFS= read -r line; do
      case "$line" in
        prompt_on_enter=*)
          value="${line#prompt_on_enter=}"
          break
          ;;
      esac
    done < "$file"
  fi
  case "$value" in
    0|off|OFF|false|False) echo 0 ;;
    1|on|ON|true|True) echo 1 ;;
    *) echo 1 ;;
  esac
}

kns_effective_prompt() {
  local prompt="${KNS_PROMPT_ON_ENTER-}"
  if [[ -n "$prompt" ]]; then
    case "$prompt" in
      0|off|OFF|false|False) echo 0 ;;
      *) echo 1 ;;
    esac
    return 0
  fi
  kns_global_prompt
}

kns_pick_env() {
  [[ -t 0 ]] || return 1
  local rest="${KNS_ENVS:-}"
  local env
  local count=0
  local default_index=""
  echo "Select kns environment:" >&2
  while [[ -n "$rest" ]]; do
    env="${rest%% *}"
    if [[ "$rest" == *" "* ]]; then
      rest="${rest#* }"
    else
      rest=""
    fi
    [[ -n "$env" ]] || continue
    count=$((count + 1))
    if [[ "$env" == "${KNS_DEFAULT_ENV:-}" ]]; then
      default_index="$count"
      printf '  %d) %s (default)\n' "$count" "$env" >&2
    else
      printf '  %d) %s\n' "$count" "$env" >&2
    fi
  done
  [[ $count -gt 0 ]] || return 1

  local choice=""
  if [[ -n "$default_index" ]]; then
    printf 'Choice [%s]: ' "$default_index" >&2
  else
    printf 'Choice: ' >&2
  fi
  IFS= read -r choice || return 1
  [[ -z "$choice" && -n "$default_index" ]] && choice="$default_index"
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  [[ $choice -ge 1 && $choice -le $count ]] || return 1

  local index=0
  rest="${KNS_ENVS:-}"
  while [[ -n "$rest" ]]; do
    env="${rest%% *}"
    if [[ "$rest" == *" "* ]]; then
      rest="${rest#* }"
    else
      rest=""
    fi
    [[ -n "$env" ]] || continue
    index=$((index + 1))
    if [[ $index -eq $choice ]]; then
      echo "$env"
      return 0
    fi
  done
  return 1
}

kns_kubectl_apply_pins() {
  [[ -n "${_kns_pin_ctx:-}" ]] || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl config use-context "$_kns_pin_ctx" >/dev/null 2>&1 || return 1
  if [[ -n "${_kns_pin_ns:-}" ]]; then
    kubectl config set-context "$_kns_pin_ctx" --namespace="$_kns_pin_ns" >/dev/null 2>&1
  fi
}

kns_apply_dir_context() {
  kns_clear_env_pins
  local KNS_CONTEXT="" KNS_NAMESPACE="" KNS_POD="" KNS_CONTAINER=""
  local KNS_ENVS="" KNS_DEFAULT_ENV="" KNS_PROMPT_ON_ENTER=""
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

  if kns_session_read && ! kns_pwd_under_root "$_kns_session_root"; then
    kns_session_clear
  fi

  if command -v kns >/dev/null 2>&1; then
    kns __pf_cleanup_left >/dev/null 2>&1 || true
  fi

  unset KNS_CONTEXT KNS_NAMESPACE KNS_POD KNS_CONTAINER \
    KNS_ENVS KNS_DEFAULT_ENV KNS_PROMPT_ON_ENTER
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

  if [[ -n "${KNS_ENVS:-}" ]]; then
    local owner
    owner=$(kns_envs_owner_dir) || owner=""
    if [[ -z "$owner" ]]; then
      return 0
    fi

    if kns_session_read; then
      if ! kns_pwd_under_root "$_kns_session_root"; then
        kns_session_clear
      elif [[ "$_kns_session_root" != "$owner" ]]; then
        kns_session_clear
      fi
    fi

    if kns_session_read && [[ "$_kns_session_root" == "$owner" ]] &&
      kns_env_in_list "$_kns_session_env"; then
      if kns_env_pins "$_kns_session_env"; then
        if ! kns_kubectl_apply_pins; then
          echo "kns: failed to apply environment '$_kns_session_env' context '$_kns_pin_ctx'" >&2
        fi
      else
        echo "kns: Environment '$_kns_session_env' has no context configured" >&2
      fi
      return 0
    fi

    local chosen=""
    local prompt
    prompt=$(kns_effective_prompt)
    if [[ "$prompt" == "1" && -t 0 ]]; then
      chosen=$(kns_pick_env) || chosen=""
    fi
    if [[ -z "$chosen" && -n "${KNS_DEFAULT_ENV:-}" ]]; then
      chosen="$KNS_DEFAULT_ENV"
    fi
    if [[ -n "$chosen" ]] && kns_env_in_list "$chosen"; then
      if ! kns_env_pins "$chosen"; then
        echo "kns: Environment '$chosen' has no context configured" >&2
      elif kns_kubectl_apply_pins; then
        kns_session_write "$owner" "$chosen"
        if [[ "${KNS_QUIET:-}" != "1" ]]; then
          echo "✓ kns env: $chosen → $_kns_pin_ctx${_kns_pin_ns:+ (ns: $_kns_pin_ns)}"
        fi
      else
        echo "kns: failed to apply environment '$chosen' context '$_kns_pin_ctx'" >&2
      fi
    elif [[ "${KNS_QUIET:-}" != "1" ]]; then
      echo "kns: no environment selected (try: kns env)" >&2
    fi
    return 0
  fi

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

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

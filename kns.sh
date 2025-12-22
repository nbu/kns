#!/usr/bin/env bash
# kns.sh - Shell integration for automatic context switching
# Source this file in your .bashrc or .zshrc

# Hook into cd command
kns_cd() {
  builtin cd "$@" || return
  
  # Find and apply context if .kns.conf exists
  # Merge values from all .kns.conf files from current directory up to root/home
  local KNS_CONTEXT=""
  local KNS_NAMESPACE=""
  local KNS_POD=""
  local KNS_CONTAINER=""
  
  # Collect all .kns.conf files from current directory up to root
  local files=()
  local dir="$PWD"
  
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.kns.conf" ]]; then
      files+=("$dir/.kns.conf")
    fi
    dir=$(dirname "$dir")
  done
  
  # Add home directory file if it exists
  if [[ -f "$HOME/.kns.conf" ]]; then
    files+=("$HOME/.kns.conf")
  fi
  
  # Debug output (enable with KNS_DEBUG=1)
  if [[ "${KNS_DEBUG:-}" == "1" ]]; then
    if [[ ${#files[@]} -gt 0 ]]; then
      echo "[kns] Found config files: ${files[*]}" >&2
    else
      echo "[kns] No config file found" >&2
    fi
  fi
  
  # Clear manual override file when directory changes (user moved to a new location)
  # This allows .kns.conf files to take effect again
  local manual_override_file="${KNS_CONFIG_DIR:-$HOME/.kns}/manual_override"
  if [[ -f "$manual_override_file" ]]; then
    rm -f "$manual_override_file"
  fi
  
  if [[ ${#files[@]} -gt 0 ]]; then
    # Source files in reverse order (parent/home first, then current)
    # This way current directory values override parent values
    local i
    for ((i=${#files[@]}-1; i>=0; i--)); do
      if [[ -f "${files[i]}" ]]; then
        source "${files[i]}" 2>/dev/null || true
      fi
    done
    
    if [[ -n "${KNS_CONTEXT:-}" ]]; then
      # Check if kubectl is available
      if command -v kubectl >/dev/null 2>&1; then
        # Get current context to avoid unnecessary switching
        local current_context=""
        current_context=$(kubectl config current-context 2>/dev/null || echo "")
        local current_namespace=""
        current_namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "")
        
        # Switch if context is different or namespace needs to be set/changed
        local needs_switch=0
        if [[ "$current_context" != "$KNS_CONTEXT" ]]; then
          needs_switch=1
        elif [[ -n "${KNS_NAMESPACE:-}" ]] && [[ "$current_namespace" != "$KNS_NAMESPACE" ]]; then
          needs_switch=1
        fi
        
        if [[ $needs_switch -eq 1 ]]; then
          # Switch context
          if kubectl config use-context "$KNS_CONTEXT" >/dev/null 2>&1; then
            # Set namespace if provided
            if [[ -n "${KNS_NAMESPACE:-}" ]]; then
              kubectl config set-context "$KNS_CONTEXT" --namespace="$KNS_NAMESPACE" >/dev/null 2>&1
            fi
            
            # Optional: show context change (can be made quiet)
            if [[ "${KNS_QUIET:-}" != "1" ]]; then
              if [[ -n "${KNS_NAMESPACE:-}" ]]; then
                echo "✓ Switched to context: $KNS_CONTEXT (namespace: $KNS_NAMESPACE)"
              else
                echo "✓ Switched to context: $KNS_CONTEXT"
              fi
            fi
          fi
        fi
      fi
    fi
  fi
}

# Override cd command
alias cd=kns_cd

# Make kns available
if command -v kns >/dev/null 2>&1; then
  # kns is already in PATH
  :
elif [[ -f "$HOME/.local/bin/kns" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi


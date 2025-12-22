#!/usr/bin/env bash
# kns.sh - Shell integration for automatic context switching
# Source this file in your .bashrc or .zshrc

# Hook into cd command
kns_cd() {
  builtin cd "$@" || return
  
  # Find and apply context if .kns.conf exists
  local dir="$PWD"
  local context_file=""
  local KNS_CONTEXT=""
  local KNS_NAMESPACE=""
  
  # Search upward from current directory
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.kns.conf" ]]; then
      context_file="$dir/.kns.conf"
      break
    fi
    dir=$(dirname "$dir")
  done
  
  # Fallback: check home directory for default context
  # Only check if no file was found in the directory tree above
  if [[ -z "$context_file" ]] && [[ -f "$HOME/.kns.conf" ]]; then
    context_file="$HOME/.kns.conf"
  fi
  
  # Debug output (enable with KNS_DEBUG=1)
  if [[ "${KNS_DEBUG:-}" == "1" ]]; then
    if [[ -n "$context_file" ]]; then
      echo "[kns] Found config: $context_file" >&2
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
  
  if [[ -n "$context_file" ]]; then
    # Source the config file to get KNS_CONTEXT and KNS_NAMESPACE
    # Use a clean environment to avoid variable pollution
    KNS_CONTEXT=""
    KNS_NAMESPACE=""
    source "$context_file" 2>/dev/null || true
    
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


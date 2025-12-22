#!/usr/bin/env bash
# Standalone installer for kns - can be installed with: curl -fsSL <url> | bash

set -euo pipefail

# Configuration
KNS_REPO_URL="${KNS_REPO_URL:-https://raw.githubusercontent.com}"
KNS_REPO_USER="${KNS_REPO_USER:-bnebosenko}"
KNS_REPO_NAME="${KNS_REPO_NAME:-kns}"
KNS_REPO_BRANCH="${KNS_REPO_BRANCH:-master}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling
error() {
  echo -e "${RED}Error: $1${NC}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}$1${NC}"
}

warn() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

# Detect shell
detect_shell() {
  local shell_rc=""
  
  if [[ -n "${SHELL:-}" ]]; then
    if [[ "$SHELL" == *"zsh"* ]]; then
      shell_rc="${HOME}/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
      shell_rc="${HOME}/.bashrc"
    fi
  fi
  
  if [[ -z "$shell_rc" ]] && [[ -f "${HOME}/.zshrc" ]]; then
    shell_rc="${HOME}/.zshrc"
  elif [[ -z "$shell_rc" ]] && [[ -f "${HOME}/.bashrc" ]]; then
    shell_rc="${HOME}/.bashrc"
  elif [[ -z "$shell_rc" ]] && command -v getent >/dev/null 2>&1; then
    local user_shell
    user_shell=$(getent passwd "$USER" | cut -d: -f7 2>/dev/null || echo "")
    if [[ "$user_shell" == *"zsh"* ]]; then
      shell_rc="${HOME}/.zshrc"
    elif [[ "$user_shell" == *"bash"* ]]; then
      shell_rc="${HOME}/.bashrc"
    fi
  fi
  
  if [[ -z "$shell_rc" ]]; then
    shell_rc="${HOME}/.bashrc"
  fi
  
  echo "$shell_rc"
}

# Download file from URL
download_file() {
  local url="$1"
  local dest="$2"
  
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest" || return 1
  else
    error "Neither curl nor wget is available. Please install one of them."
  fi
}

# Main installation
main() {
  info "Installing kns - Kubernetes Namespace/Context Switcher"
  echo ""
  
  # Check if we're being run from a git repo (local installation)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if kns and kns.sh exist locally
  if [[ -f "$script_dir/kns" ]] && [[ -f "$script_dir/kns.sh" ]]; then
    info "Found local files, installing from current directory..."
    local source_dir="$script_dir"
  else
    # Try to detect repository from git remote if available
    if [[ -d "$script_dir/.git" ]] && command -v git >/dev/null 2>&1; then
      local git_remote
      git_remote=$(cd "$script_dir" && git remote get-url origin 2>/dev/null || echo "")
      if [[ -n "$git_remote" ]]; then
        # Extract user/repo from git URL
        if [[ "$git_remote" =~ github.com[:/]([^/]+)/([^/]+) ]]; then
          KNS_REPO_USER="${BASH_REMATCH[1]}"
          KNS_REPO_NAME="${BASH_REMATCH[2]%.git}"
        fi
      fi
    fi
    
    # Download from repository (using defaults if not specified)
    info "Downloading kns from repository: ${KNS_REPO_USER}/${KNS_REPO_NAME}..."
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    local base_url="${KNS_REPO_URL}/${KNS_REPO_USER}/${KNS_REPO_NAME}/${KNS_REPO_BRANCH}"
    
    info "Downloading kns script..."
    if ! download_file "${base_url}/kns" "${temp_dir}/kns"; then
      error "Failed to download kns script from ${base_url}/kns"
    fi
    
    info "Downloading kns.sh script..."
    if ! download_file "${base_url}/kns.sh" "${temp_dir}/kns.sh"; then
      error "Failed to download kns.sh script from ${base_url}/kns.sh"
    fi
    
    local source_dir="$temp_dir"
  fi
  
  # Create install directory
  mkdir -p "$INSTALL_DIR"
  info "Install directory: $INSTALL_DIR"
  
  # Copy files
  info "Installing kns..."
  cp "${source_dir}/kns" "$INSTALL_DIR/kns"
  chmod +x "$INSTALL_DIR/kns"
  info "✓ Installed kns to $INSTALL_DIR/kns"
  
  info "Installing kns.sh..."
  cp "${source_dir}/kns.sh" "$INSTALL_DIR/kns.sh"
  chmod +x "$INSTALL_DIR/kns.sh"
  info "✓ Installed kns.sh to $INSTALL_DIR/kns.sh"
  
  # Detect shell and update rc file
  local shell_rc
  shell_rc=$(detect_shell)
  
  if [[ -f "$shell_rc" ]]; then
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
      info "Adding $INSTALL_DIR to PATH in $shell_rc"
      {
        echo ""
        echo "# kns - Kubernetes context switcher"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
      } >> "$shell_rc"
    fi
    
    # Source shell integration
    if ! grep -q "kns.sh" "$shell_rc" 2>/dev/null; then
      info "Adding kns shell integration to $shell_rc"
      {
        echo ""
        echo "# Source kns shell integration"
        echo "source $INSTALL_DIR/kns.sh"
      } >> "$shell_rc"
    fi
  fi
  
  echo ""
  info "✓ Installation complete!"
  echo ""
  echo "To start using kns:"
  echo "  1. Run: source $shell_rc"
  echo "  2. Or restart your terminal"
  echo ""
  echo "Then try: kns help"
}

main "$@"


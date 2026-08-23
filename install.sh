#!/usr/bin/env bash
# install.sh - Install kns tool

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SHELL_RC=""

# Detect shell - check user's default shell, not the script's shell
# First try $SHELL environment variable
if [[ -n "${SHELL:-}" ]]; then
  if [[ "$SHELL" == *"zsh"* ]]; then
    SHELL_RC="${HOME}/.zshrc"
  elif [[ "$SHELL" == *"bash"* ]]; then
    SHELL_RC="${HOME}/.bashrc"
  fi
fi

# Fallback: check if .zshrc exists (user likely uses zsh)
if [[ -z "$SHELL_RC" ]] && [[ -f "${HOME}/.zshrc" ]]; then
  SHELL_RC="${HOME}/.zshrc"
# Fallback: check if .bashrc exists
elif [[ -z "$SHELL_RC" ]] && [[ -f "${HOME}/.bashrc" ]]; then
  SHELL_RC="${HOME}/.bashrc"
# Fallback: try to get shell from /etc/passwd (Linux/WSL)
elif [[ -z "$SHELL_RC" ]] && command -v getent >/dev/null 2>&1; then
  USER_SHELL=$(getent passwd "$USER" | cut -d: -f7 2>/dev/null || echo "")
  if [[ "$USER_SHELL" == *"zsh"* ]]; then
    SHELL_RC="${HOME}/.zshrc"
  elif [[ "$USER_SHELL" == *"bash"* ]]; then
    SHELL_RC="${HOME}/.bashrc"
  fi
fi

# Final fallback: default to .bashrc if nothing found
if [[ -z "$SHELL_RC" ]]; then
  echo "Warning: Could not detect shell. Defaulting to .bashrc" >&2
  echo "If you use zsh, please manually add kns.sh to your ~/.zshrc" >&2
  SHELL_RC="${HOME}/.bashrc"
fi

echo "Installing kns..."

# Create install directory
mkdir -p "$INSTALL_DIR"

# Get the directory where install.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy main script
if [[ -f "$SCRIPT_DIR/kns" ]]; then
  cp "$SCRIPT_DIR/kns" "$INSTALL_DIR/kns"
  chmod +x "$INSTALL_DIR/kns"
  echo "✓ Installed kns to $INSTALL_DIR/kns"
else
  echo "Error: kns script not found in $SCRIPT_DIR" >&2
  exit 1
fi

# Copy shell integration
if [[ -f "$SCRIPT_DIR/kns.sh" ]]; then
  cp "$SCRIPT_DIR/kns.sh" "$INSTALL_DIR/kns.sh"
  chmod +x "$INSTALL_DIR/kns.sh"
  echo "✓ Installed kns.sh to $INSTALL_DIR/kns.sh"
else
  echo "Error: kns.sh script not found in $SCRIPT_DIR" >&2
  exit 1
fi

# Add to PATH if not already there
if [[ -n "$SHELL_RC" ]] && [[ -f "$SHELL_RC" ]]; then
  if ! grep -qF "$INSTALL_DIR" "$SHELL_RC" 2>/dev/null; then
    echo "Adding $INSTALL_DIR to PATH in $SHELL_RC"
    echo "" >> "$SHELL_RC"
    echo "# kns - Kubernetes context switcher" >> "$SHELL_RC"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_RC"
  fi

  # Source shell integration
  if ! grep -q "kns.sh" "$SHELL_RC" 2>/dev/null; then
    echo "Adding kns shell integration to $SHELL_RC"
    echo "" >> "$SHELL_RC"
    echo "# Source kns shell integration" >> "$SHELL_RC"
    echo "source $INSTALL_DIR/kns.sh" >> "$SHELL_RC"
  fi
fi

# Shell completions
if [[ -x "$INSTALL_DIR/kns" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    echo -n "Install shell completions? [Y/n] "
    _kns_comp_ans=""
    read -r _kns_comp_ans || true
    case "${_kns_comp_ans:-Y}" in
      n|N|no|No)
        echo "Skipping completions. Later: kns completion install"
        ;;
      *)
        echo -n "Completion mode: (1) static  (2) live  [1] "
        _kns_mode_ans=""
        read -r _kns_mode_ans || true
        _kns_mode=static
        case "${_kns_mode_ans:-1}" in
          2|live) _kns_mode=live ;;
        esac
        "$INSTALL_DIR/kns" completion install --mode "$_kns_mode" || true
        ;;
    esac
  else
    "$INSTALL_DIR/kns" completion install --mode static || true
  fi
fi

echo ""
echo "✓ Installation complete!"
echo ""
if [[ -n "$SHELL_RC" ]]; then
  echo "Please run: source $SHELL_RC"
  echo "Or restart your terminal."
else
  echo "Please add the following to your shell rc file:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo "  source $INSTALL_DIR/kns.sh"
fi


#!/usr/bin/env bash
# gadz installer — installs client prerequisites and wires gadz into ~/.zshrc.
# Idempotent: safe to re-run. Run from anywhere; it locates itself.
#
#   ./config-files/shell/install.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gadz="$here/gadz.zsh"
zshrc="${ZDOTDIR:-$HOME}/.zshrc"

# 1. prereqs
if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required. Install it first: https://brew.sh" >&2
  exit 1
fi
for dep in zsh-autosuggestions zsh-syntax-highlighting; do
  if brew list "$dep" >/dev/null 2>&1; then
    echo "ok: $dep already installed"
  else
    echo "installing: $dep"
    brew install "$dep"
  fi
done

# 2. wire into ~/.zshrc
line="source \"$gadz\""
if [ -f "$zshrc" ] && grep -qF "$line" "$zshrc"; then
  echo "ok: ~/.zshrc already sources gadz"
else
  { echo ""; echo "# gadz — ephemeral remote shell (home0ps)"; echo "$line"; } >> "$zshrc"
  echo "added: gadz source line to $zshrc"
fi

echo
echo "done — gadz installed."
# A script can't reload its parent shell (different process), so drop into a
# fresh interactive shell that has gadz loaded. Skipped when not on a TTY.
if [ -t 0 ] && [ -t 1 ]; then
  echo "starting a fresh shell so gadz is ready — run:  gadz user@host"
  exec "${SHELL:-/bin/zsh}" -i
else
  echo "reload your shell:  exec \"\${SHELL:-/bin/zsh}\"   then:  gadz user@host"
fi

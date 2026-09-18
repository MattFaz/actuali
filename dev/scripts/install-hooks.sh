#!/usr/bin/env bash
# Install project git hooks into .git/hooks/.
# Run once after cloning: bash dev/scripts/install-hooks.sh

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
HOOKS_SRC="$REPO_ROOT/dev/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

for hook in "$HOOKS_SRC"/*; do
  name="$(basename "$hook")"
  target="$HOOKS_DST/$name"
  cp "$hook" "$target"
  chmod +x "$target"
  echo "Installed $name → .git/hooks/$name"
done

echo "Done. Git hooks installed."

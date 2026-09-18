#!/usr/bin/env bash
# Installs the project's git hooks (one-time per clone/worktree — git does
# not copy hooks). The hook is symlinked, so updates to dev/scripts/pre-commit
# apply to every clone that ran this script.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
hook_dst="$(git rev-parse --git-path hooks)/pre-commit"
link_target="$(pwd)/dev/scripts/pre-commit"

if [ -e "$hook_dst" ] && [ "$(readlink "$hook_dst" 2>/dev/null || true)" != "$link_target" ]; then
    echo "error: $hook_dst already exists and is not ours — remove it first if you want the SwiftFormat hook installed" >&2
    exit 1
fi

ln -sf "$link_target" "$hook_dst"
echo "Installed pre-commit hook -> $hook_dst"

#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "Usage: runtime-bin <command> [arguments...]" >&2
    exit 2
fi

command_name=$1
shift
claude_root=${CLAUDE_HOME:-"$HOME/.claude"}
codex_root=${CODEX_HOME:-"$HOME/.codex"}

for candidate in "$claude_root/bin/$command_name" "$codex_root/bin/$command_name"; do
    if [ -x "$candidate" ] && [ "$(basename "$candidate")" != "runtime-bin" ]; then
        exec "$candidate" "$@"
    fi
done

echo "ERROR: Runtime command is not installed: $command_name" >&2
exit 127

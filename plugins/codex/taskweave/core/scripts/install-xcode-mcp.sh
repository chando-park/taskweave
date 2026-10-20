#!/bin/sh

set -eu

client=both
mode=install
usage() { echo "Usage: install-xcode-mcp.sh [--client codex|claude|both] [--check|--dry-run]" >&2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --client) client=${2:-}; shift 2 ;;
        --check) mode=check; shift ;;
        --dry-run) mode=dry-run; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
case "$client" in codex|claude|both) ;; *) usage; exit 2 ;; esac

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find mcpbridge >/dev/null 2>&1; then
    echo "ERROR: selected Xcode does not provide mcpbridge. Install/select Xcode first." >&2
    exit 1
fi

check_client() {
    name=$1 cli=$2 get_command=$3 add_command=$4
    if ! command -v "$cli" >/dev/null 2>&1; then echo "SKIPPED: $name CLI is unavailable."; return 0; fi
    existing=$(sh -c "$get_command" 2>/dev/null || true)
    if [ -n "$existing" ]; then
        if printf '%s' "$existing" | grep -Eq 'xcrun[[:space:]]+mcpbridge'; then echo "OK: $name Xcode MCP is already registered."; return 0; fi
        echo "CONFLICT: $name already has an xcode MCP with a different command." >&2; return 1
    fi
    case "$mode" in
        check) echo "MISSING: $name Xcode MCP registration."; return 1 ;;
        dry-run) echo "PLAN: $add_command" ;;
        install) sh -c "$add_command"; echo "REGISTERED: $name Xcode MCP." ;;
    esac
}

failed=0
case "$client" in codex|both) check_client "Codex" codex "codex mcp get xcode" "codex mcp add xcode -- xcrun mcpbridge" || failed=1 ;; esac
case "$client" in claude|both) check_client "Claude" claude "claude mcp get xcode" "claude mcp add --scope user --transport stdio xcode -- xcrun mcpbridge" || failed=1 ;; esac
[ "$failed" -eq 0 ] || exit 1
echo "NEXT: enable external-agent access in Xcode Settings > Intelligence, then restart the selected client."

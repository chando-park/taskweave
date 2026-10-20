#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
inventory="$runtime_root/runtime-inventory.yml"
client=both platform=core mode=install full_doctor=0
usage() { echo "Usage: bootstrap.sh [--client codex|claude|both] [--platform core|apple|android] [--check] [--dry-run] [--full-doctor]" >&2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --client) client=${2:-}; shift 2 ;;
        --platform) platform=${2:-}; shift 2 ;;
        --check) mode=check; shift ;;
        --dry-run) mode=dry-run; shift ;;
        --full-doctor) full_doctor=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
case "$client" in codex|claude|both) ;; *) usage; exit 2 ;; esac
case "$platform" in core|apple|android) ;; *) usage; exit 2 ;; esac
[ "$mode" != check ] || [ "$full_doctor" -eq 0 ] || { echo "ERROR: --check and --full-doctor cannot be combined" >&2; exit 2; }

adapter_for() { ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$inventory" --kind client | awk -F '\t' -v wanted="$1" '$1 == wanted { print $2 "\t" $3 }'; }
platform_adapter_for() { ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$inventory" --kind platform | awk -F '\t' -v wanted="$1" '$1 == wanted { print $2 "\t" $3 "\t" $4 "\t" $5 }'; }
run_client() {
    selected=$1 adapter=$(adapter_for "$1")
    [ -n "$adapter" ] || { echo "ERROR: missing client adapter: $selected" >&2; return 1; }
    installer="$runtime_root/$(printf '%s' "$adapter" | cut -f1)" doctor="$runtime_root/$(printf '%s' "$adapter" | cut -f2)"
    [ -f "$installer" ] && [ -f "$doctor" ] || { echo "ERROR: invalid $selected adapter paths" >&2; return 1; }
    case "$mode" in
        dry-run) echo "PLAN: $selected install $installer"; echo "PLAN: $selected doctor $doctor --installation-only" ;;
        check) sh "$doctor" --installation-only ;;
        install) sh "$installer"; if [ "$full_doctor" -eq 1 ]; then sh "$doctor"; else sh "$doctor" --installation-only; fi ;;
    esac
}
run_command_check() {
    required_commands=$1 optional_commands=$2
    status=0
    old_ifs=$IFS; IFS=,
    for command_name in $required_commands; do
        [ -n "$command_name" ] || continue
        if command -v "$command_name" >/dev/null 2>&1; then echo "REQUIRED ready: $command_name"; else echo "REQUIRED missing: $command_name"; status=1; fi
    done
    for command_name in $optional_commands; do
        [ -n "$command_name" ] || continue
        if command -v "$command_name" >/dev/null 2>&1; then echo "OPTIONAL ready: $command_name"; else echo "OPTIONAL missing: $command_name"; fi
    done
    IFS=$old_ifs
    if [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then echo "ANDROID_SDK ready"; else echo "ANDROID_SDK missing"; status=1; fi
    return "$status"
}
case "$client" in codex) run_client codex ;; claude) run_client claude ;; both) run_client codex && run_client claude ;; esac
platform_adapter=$(platform_adapter_for "$platform")
[ -n "$platform_adapter" ] || { echo "ERROR: missing platform adapter: $platform" >&2; exit 1; }
platform_mode=$(printf '%s' "$platform_adapter" | cut -f1)
platform_installer=$(printf '%s' "$platform_adapter" | cut -f2)
required_commands=$(printf '%s' "$platform_adapter" | cut -f3)
optional_commands=$(printf '%s' "$platform_adapter" | cut -f4)
case "$platform_mode" in
    built-in) echo "Platform $platform: no additional adapter." ;;
    optional-installer)
        [ -n "$platform_installer" ] || { echo "ERROR: missing installer for platform $platform" >&2; exit 1; }
        platform_script="$runtime_root/$platform_installer"
        case "$mode" in check) sh "$platform_script" --client "$client" --check ;; dry-run) sh "$platform_script" --client "$client" --dry-run ;; install) sh "$platform_script" --client "$client" ;; esac
        ;;
    check-only)
        if [ "$mode" = dry-run ]; then echo "PLAN: $platform environment check only"; else run_command_check "$required_commands" "$optional_commands"; fi
        ;;
    *) echo "ERROR: unsupported platform mode: $platform_mode" >&2; exit 1 ;;
esac
echo "Bootstrap finished: client=$client platform=$platform mode=$mode"

#!/bin/sh

set -eu

# 기존 링크 설치는 유지하며, 사용자가 선택한 경우에만 플러그인 설치로 보낸다.
if [ "${1:-}" = "--plugin" ]; then
    shift
    plugin_bootstrap="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/20_AI/WorkflowPlugin/scripts/bootstrap.sh"
    exec sh "$plugin_bootstrap" --client codex --install "$@"
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
wiki_root=$(CDPATH= cd -- "$runtime_root/../../.." && pwd)
codex_root=${CODEX_HOME:-"$HOME/.codex"}

mkdir -p "$codex_root/skills"
mkdir -p "$codex_root/agents"
mkdir -p "$codex_root/bin"

link_item() {
    source_path=$1
    target_path=$2

    if [ -L "$target_path" ]; then
        current_target=$(readlink "$target_path")
        if [ "$current_target" = "$source_path" ]; then
            echo "OK: $target_path"
            return
        fi
        if [ ! -e "$target_path" ]; then
            unlink "$target_path"
            ln -s "$source_path" "$target_path"
            echo "REPAIRED: $target_path"
            return
        fi
        echo "CONFLICT: $target_path -> $current_target" >&2
        exit 1
    fi

    if [ -e "$target_path" ]; then
        echo "CONFLICT: existing path $target_path" >&2
        exit 1
    fi

    ln -s "$source_path" "$target_path"
    echo "LINKED: $target_path"
}

remove_deprecated_link() {
    target_path=$1
    owned_source=$2

    if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$owned_source" ]; then
        unlink "$target_path"
        echo "REMOVED: deprecated $target_path"
    fi
}

link_item "$runtime_root/AGENTS.md" "$codex_root/AGENTS.md"
link_item "$wiki_root" "$codex_root/personal-wiki"
link_item "$runtime_root/references" "$codex_root/references"
link_item "$runtime_root/agents/general-terra.toml" "$codex_root/agents/general-terra.toml"
link_item "$runtime_root/agents/routine-luna.toml" "$codex_root/agents/routine-luna.toml"
link_item "$runtime_root/agents/high-risk-sol.toml" "$codex_root/agents/high-risk-sol.toml"
link_item "$runtime_root/agents/ui-spark.toml" "$codex_root/agents/ui-spark.toml"

while IFS="	" read -r bin_name bin_source; do
    link_item "$runtime_root/$bin_source" "$codex_root/bin/$bin_name"
done <<EOF
$(ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$runtime_root/runtime-inventory.yml" --kind bin)
EOF

if [ -L "$codex_root/company-workspace" ]; then
    active_company_root=$(readlink "$codex_root/company-workspace")
    remove_deprecated_link "$codex_root/skills/complete-work" "$active_company_root/AI/skills/complete-work"
fi

while IFS= read -r skill_name; do
    link_item "$runtime_root/skills/$skill_name" "$codex_root/skills/$skill_name"
done <<EOF
$(ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$runtime_root/runtime-inventory.yml" --kind personal-skill)
EOF
remove_deprecated_link "$codex_root/skills/design-system-component" "$runtime_root/skills/design-system-component"

echo "Codex Runtime is installed. Run the Claude Runtime installer separately, or use bootstrap.sh --client both. Restart Codex to refresh skills and agents."

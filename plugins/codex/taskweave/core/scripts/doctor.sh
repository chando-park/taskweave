#!/bin/sh

set -eu

if [ "${1:-}" = "--plugin" ]; then
    shift
    plugin_bootstrap="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/20_AI/WorkflowPlugin/scripts/bootstrap.sh"
    exec sh "$plugin_bootstrap" --client codex --check "$@"
fi

installation_only=0
case "${1:-}" in
    "") ;;
    --installation-only) installation_only=1 ;;
    *) echo "Usage: doctor.sh [--installation-only]" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
wiki_root=$(CDPATH= cd -- "$runtime_root/../../.." && pwd)
codex_root=${CODEX_HOME:-"$HOME/.codex"}
failed=0

check_link() {
    target_path=$1
    expected_source=$2

    if [ -L "$target_path" ] &&
       [ -e "$target_path" ] &&
       [ "$(readlink "$target_path")" = "$expected_source" ]; then
        echo "OK: $target_path -> $expected_source"
        return
    fi

    if [ -L "$target_path" ]; then
        echo "MISSING OR WRONG: $target_path -> $(readlink "$target_path")" >&2
    else
        echo "MISSING OR WRONG: $target_path" >&2
    fi
    failed=1
}

check_link "$codex_root/AGENTS.md" "$runtime_root/AGENTS.md"
check_link "$codex_root/personal-wiki" "$wiki_root"
check_link "$codex_root/references" "$runtime_root/references"
check_link "$codex_root/agents/general-terra.toml" "$runtime_root/agents/general-terra.toml"
check_link "$codex_root/agents/routine-luna.toml" "$runtime_root/agents/routine-luna.toml"
check_link "$codex_root/agents/high-risk-sol.toml" "$runtime_root/agents/high-risk-sol.toml"
check_link "$codex_root/agents/ui-spark.toml" "$runtime_root/agents/ui-spark.toml"
while IFS="	" read -r bin_name bin_source; do
    check_link "$codex_root/bin/$bin_name" "$runtime_root/$bin_source"
done <<EOF
$(ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$runtime_root/runtime-inventory.yml" --kind bin)
EOF
while IFS= read -r skill_name; do
    check_link "$codex_root/skills/$skill_name" "$runtime_root/skills/$skill_name"
done <<EOF
$(ruby "$runtime_root/scripts/runtime-inventory.rb" --inventory "$runtime_root/runtime-inventory.yml" --kind personal-skill)
EOF

if [ -L "$codex_root/skills/design-system-component" ] &&
   [ "$(readlink "$codex_root/skills/design-system-component")" = "$runtime_root/skills/design-system-component" ]; then
    echo "STALE: deprecated $codex_root/skills/design-system-component" >&2
    failed=1
fi

for reference in execution-contract.md risk-routing.md model-routing.md implementation-handoff.md code-comment-contract.md rule-enforcement.md runtime-evaluation.md context-pack.md serena-code-intelligence.md verification-planning.md verification-evidence.md ui-verification.md repository-artifact-boundary.md swift-testing-contract.md workplan-metadata.md git-operation-contract.md company-workplan-adapter.md ticket-lifecycle.md design-system-implementation-contract.md workplan-layout.md; do
    if [ ! -f "$runtime_root/references/$reference" ]; then
        echo "MISSING: $runtime_root/references/$reference" >&2
        failed=1
    fi
done

if [ "$installation_only" -eq 0 ]; then
    if ! ruby "$runtime_root/scripts/resolve-task-context.rb" "$wiki_root" --expect-repository "$(basename "$wiki_root")" >/dev/null; then
        echo "Task context resolver failed for personal wiki." >&2
        failed=1
    fi

    if ! ruby "$runtime_root/scripts/resolve-workplan-policy.rb" "$wiki_root" --kind feature >/dev/null; then
        echo "Workplan policy resolver failed for personal wiki." >&2
        failed=1
    fi

    if ! ruby "$runtime_root/scripts/lint-personal-workplans.rb" \
        --root "$wiki_root/20_AI/Codex/Workplans/personal-ai-system" \
        --repository-root "$wiki_root" >/dev/null; then
        echo "Personal Workplan lint failed." >&2
        failed=1
    fi
fi

if [ ! -x "$runtime_root/scripts/resolve-context-pack.rb" ] ||
   ! ruby "$runtime_root/scripts/resolve-context-pack.rb" --profile logic >/dev/null; then
    echo "Context profile resolver failed." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/feature-plan-gate.rb" ]; then
    echo "Feature plan completeness gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/workplan-approval-projection.rb" ]; then
    echo "Workplan approval projection is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/ui-verification-gate.rb" ]; then
    echo "UI verification gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/ui-image-compare.rb" ]; then
    echo "UI image comparator is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/artifact-placement-gate.rb" ]; then
    echo "Artifact placement gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/implementation-explanation-gate.rb" ]; then
    echo "Implementation explanation gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/micro-ui-feedback-gate.rb" ]; then
    echo "Micro UI feedback gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/serena-preflight.rb" ]; then
    echo "Serena preflight gate is missing or not executable." >&2
    failed=1
fi

if [ ! -x "$runtime_root/scripts/workplan-memo.rb" ]; then
    echo "Workplan approval memo command is missing or not executable." >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo "Codex personal settings need installation or repair." >&2
    exit 1
fi

if [ "$installation_only" -eq 1 ]; then
    echo "Codex installation links and commands are connected."
else
    echo "Codex personal settings, model-routing agents and Runtime commands are connected."
fi

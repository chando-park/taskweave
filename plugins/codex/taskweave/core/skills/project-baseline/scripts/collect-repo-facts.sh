#!/bin/sh

set -eu

requested_path=${1:-.}
repo_root=$(git -C "$requested_path" rev-parse --show-toplevel)
commit_sha=$(git -C "$repo_root" rev-parse HEAD)
branch_name=$(git -C "$repo_root" branch --show-current)
dirty_count=$(git -C "$repo_root" status --short | wc -l | tr -d ' ')
remote_origin=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)

redact_remote() {
    printf '%s\n' "$1" | sed -E 's#(https?://)[^/@]+@#\1***@#'
}

relative_file_list() {
    category=$1

    case "$category" in
        instructions)
            find "$repo_root" -maxdepth 6 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type f \( -name AGENTS.md -o -name CLAUDE.md -o -name copilot-instructions.md \
                -o -name '*.instructions.md' \) -print
            ;;
        manifests)
            find "$repo_root" -maxdepth 6 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type f \( -name Package.swift -o -name Project.swift -o -name Workspace.swift -o -name Tuist.swift \
                -o -name Podfile -o -name Cartfile -o -name project.yml -o -name Makefile \
                -o -name package.json -o -name Gemfile -o -name project.pbxproj \) -print
            ;;
        documentation)
            find "$repo_root" -maxdepth 8 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type f \( -iname 'README*' -o -iname 'ARCHITECTURE*' -o -iname 'ADR*' \
                -o -iname '*SPEC*.md' -o -iname '*PROTOCOL*.md' -o -iname '*DESIGN*.md' \
                -o -path '*/Docs/*' -o -path '*/docs/*' \) ! -name '.DS_Store' -print
            ;;
        contracts)
            find "$repo_root" -maxdepth 12 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type f \( -iname '*openapi*' -o -iname '*swagger*' -o -iname '*postman*' \
                -o -iname '*.proto' -o -iname '*.graphql' -o -iname '*.graphqls' -o -iname '*.avsc' \
                -o -iname '*.thrift' -o -iname '*.wsdl' -o -path '*/Router/*' -o -path '*/Routers/*' \
                -o -path '*/DTO/*' -o -path '*/Protocol/*' -o -path '*/Packet/*' \
                -o -path '*/Command/*' \) -print
            ;;
        persistence)
            find "$repo_root" -maxdepth 12 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Derived' -o -path '*.xcodeproj' -o -path '*.xcworkspace' \
                -o -path '*/xcuserdata' -o -path '*/Pods' -o -path '*/Carthage' \
                -o -path '*/node_modules' \) -prune -o \
                -type f \( -iname '*.sql' -o -iname '*schema*' -o -iname '*migration*' \
                -o -path '*/Migrations/*' -o -path '*/Database/*' -o -path '*/DB/*' \) -print
            ;;
        automation)
            find "$repo_root" -maxdepth 8 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type f \( -name '.gitlab-ci.yml' -o -path '*/.github/workflows/*' \
                -o -path '*/fastlane/*' -o -name 'Fastfile' -o -name 'Jenkinsfile' \
                -o -name 'Dockerfile' -o -name 'docker-compose.yml' -o -path '*/Scripts/*' \
                -o -path '*/scripts/*' \) -print
            ;;
        tests)
            find "$repo_root" -maxdepth 10 \
                \( -path '*/.git' -o -path '*/.serena' -o -path '*/.build' -o -path '*/DerivedData' \
                -o -path '*/Pods' -o -path '*/Carthage' -o -path '*/node_modules' \) -prune -o \
                -type d \( -name Tests -o -name '*Tests' -o -name test -o -name tests \) -print
            ;;
        *)
            return 1
            ;;
    esac |
        sed "s#^$repo_root/##" |
        LC_ALL=C sort -u |
        sed -n '1,120p'
}

printf 'repo_root\t%s\n' "$repo_root"
printf 'commit\t%s\n' "$commit_sha"
printf 'branch\t%s\n' "${branch_name:-DETACHED}"
printf 'dirty_files\t%s\n' "$dirty_count"
printf 'remote_origin\t%s\n' "$(redact_remote "$remote_origin")"

for category in instructions manifests documentation contracts persistence automation tests; do
    printf '\n[%s]\n' "$category"
    relative_file_list "$category"
done

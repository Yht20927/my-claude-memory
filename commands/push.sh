#!/bin/bash
# ============================================================================
# mcmPush - 提交并推送记忆变更到 git remote (v4.0 Phase 7)
# ============================================================================
# Usage:
#   mcmPush [--remote <name>] [--all] [--message <msg>]
#
# 默认推 origin；--remote <name> 指定；--all 遍历所有 remote。
# 单个 remote 失败不阻断其他；汇总失败，exit code 反映。
# 尊重 .gitignore：只 stage 真记忆（chunks/summary/log/ledger + l4/ device registry）。
# 有 staged 变更则提交；有未推送 commit（含 mcmPull --continue 的 merge commit）则推送。
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

REMOTE_NAME=""
PUSH_ALL=false
MESSAGE=""
GIT_LOCK="mcm-git"

usage() {
    cat <<EOF
用法: mcmPush [--remote <name>] [--all] [--message <msg>]
  默认推 origin；--remote 指定单个；--all 遍历所有 remote。
  --message 覆盖自动生成的 commit message（默认从变更记忆名归约）。
EOF
    exit "${1:-0}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote) REMOTE_NAME="$2"; shift 2 ;;
            --all)    PUSH_ALL=true; shift ;;
            --message) MESSAGE="$2"; shift 2 ;;
            --help|-h) usage 0 ;;
            *) echo "未知参数: $1"; usage 1 ;;
        esac
    done
}

# 从 staged 变更归约记忆名列表（projects/<tag>/<name> 或 global/<mode>/<name>）
_derive_changed_memories() {
    git diff --cached --name-only 2>/dev/null | awk -F/ '
        ($1=="projects" || $1=="global") && NF>=3 { print $1"/"$2"/"$3; next }
        { print "(config)" }
    ' | sort -u | paste -sd', ' -
}

_git_commit() {
    local msg="$1"
    git commit -q -m "$msg" 2>/dev/null \
        || git -c user.name="mcm" -c user.email="mcm@local" commit -q -m "$msg"
}

# 计算相对 <remote>/<branch> 未推送的 commit 数；无跟踪分支则本地全部
_count_unpushed() {
    local remote="$1" branch="$2"
    if git rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
        git rev-list --count "$remote/$branch..HEAD" 2>/dev/null || echo 0
    else
        git rev-list --count HEAD 2>/dev/null || echo 0
    fi
}

_push_to() {
    local remote="$1"
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo main)
    if git push "$remote" "$branch" 2>/tmp/mcm_push.err; then
        echo "  ✓ $remote/$branch"
        return 0
    else
        echo "  ✗ $remote (失败):"
        sed 's/^/      /' /tmp/mcm_push.err 2>/dev/null || true
        return 1
    fi
}

main() {
    parse_args "$@"

    command -v git &>/dev/null || { echo "错误: 未找到 git"; exit 1; }

    local lock_token
    lock_token=$(acquire_lock "$GIT_LOCK")
    mcm_on_exit "release_lock '$GIT_LOCK' '$lock_token'"

    cd "$MEMORY_BASE"

    [ -d .git ] || { echo "错误: $MEMORY_BASE 不是 git 仓库，先 mcmRemote init"; exit 1; }

    # 至少一个 remote
    if ! git remote | grep -q . 2>/dev/null; then
        echo "错误: 未配置 remote，先用 mcmRemote add <name> <url>"
        exit 1
    fi

    # stage 真记忆（尊重 .gitignore）
    git add -A

    local has_staged=false
    if ! git diff --cached --quiet 2>/dev/null; then has_staged=true; fi

    # 提交新变更
    if [ "$has_staged" = true ]; then
        local msg
        if [ -n "$MESSAGE" ]; then
            msg="$MESSAGE"
        else
            local memories
            memories=$(_derive_changed_memories)
            [ -z "$memories" ] && memories="(无)"
            msg="mcm: sync $memories"
        fi
        _git_commit "$msg"
        echo "✓ 已提交: $msg"
        emit_event "push" message="$msg"
    fi

    # 计算未推送 commit（含刚提交的 + mcmPull --continue 等遗留的 merge commit）
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo main)

    if [ "$has_staged" = false ]; then
        local target="${REMOTE_NAME:-origin}"
        local unpushed
        unpushed=$(_count_unpushed "$target" "$branch")
        if [ "${unpushed:-0}" -eq 0 ]; then
            echo "• 无变更，跳过推送"
            exit 0
        fi
        echo "• 无新 staged 变更，但有 $unpushed 个未推送 commit，继续推送"
    fi

    # push
    local failed=0
    if [ "$PUSH_ALL" = true ]; then
        echo "推送到所有 remote:"
        local r
        while IFS= read -r r; do
            _push_to "$r" || failed=$((failed+1))
        done < <(git remote)
    else
        local target="${REMOTE_NAME:-origin}"
        echo "推送到 $target:"
        _push_to "$target" || failed=$((failed+1))
    fi

    [ "$failed" -gt 0 ] && { echo "⚠ $failed 个 remote 推送失败"; exit 1; }
    echo "✓ 推送完成"
}

mcm_run_command main "$@"

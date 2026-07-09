#!/bin/bash
# ============================================================================
# mcmPull - 拉取并合并远程记忆 (v4.0 Phase 7)
# ============================================================================
# Usage:
#   mcmPull [--remote <name>]
#   mcmPull --abort                      放弃合并，回到合并前
#   mcmPull --ours <file>                单文件取本方版本
#   mcmPull --theirs <file>              单文件取对方版本
#   mcmPull --continue                   解决冲突后提交合并
#
# 默认 fetch + merge origin/main。append-only 日志(log.md/ledger.md)经
# .gitattributes merge=union 自动合并；改写式文件(summary.md/chunks)冲突不静默。
# 成功后重建派生文件(.search_index + 缺失 index.md)。
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

REMOTE_NAME=""
ACTION=""
RESOLVE_FILE=""
GIT_LOCK="mcm-git"

usage() {
    cat <<EOF
用法:
  mcmPull [--remote <name>]                拉取并合并（默认 origin）
  mcmPull --abort                          放弃当前合并
  mcmPull --ours <file>                    单文件取本方版本
  mcmPull --theirs <file>                  单文件取对方版本
  mcmPull --continue                       解决冲突后提交合并
EOF
    exit "${1:-0}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote) REMOTE_NAME="$2"; shift 2 ;;
            --abort)  ACTION="abort"; shift ;;
            --continue) ACTION="continue"; shift ;;
            --ours)   ACTION="ours"; shift; [[ $# -ge 1 ]] || { echo "用法: --ours <file>"; exit 1; }; RESOLVE_FILE="$1"; shift ;;
            --theirs) ACTION="theirs"; shift; [[ $# -ge 1 ]] || { echo "用法: --theirs <file>"; exit 1; }; RESOLVE_FILE="$1"; shift ;;
            --help|-h) usage 0 ;;
            *) echo "未知参数: $1"; usage 1 ;;
        esac
    done
}

_git_commit() {
    local msg="$1"
    git commit -q -m "$msg" 2>/dev/null \
        || git -c user.name="mcm" -c user.email="mcm@local" commit -q -m "$msg"
}

# 打印冲突文件 + 引导
_report_conflicts() {
    local conflicts
    conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)
    echo ""
    echo "✗ 检测到冲突，需手动解决:"
    printf '%s\n' "$conflicts" | sed 's/^/    /' | grep -v '^$' || true
    echo ""
    echo "  解决后: mcmPull --continue        (提交合并)"
    echo "  放弃:   mcmPull --abort            (回到合并前)"
    echo "  单方:   mcmPull --ours|--theirs <file>"
}

# ----------------------------------------------------------------------------
# --abort
# ----------------------------------------------------------------------------
cmd_abort() {
    cd "$MEMORY_BASE"
    git merge --abort 2>/dev/null && echo "✓ 已放弃合并（回到合并前）" \
        || echo "• 当前无进行中的合并"
}

# ----------------------------------------------------------------------------
# --ours / --theirs <file>
# ----------------------------------------------------------------------------
cmd_resolve() {
    cd "$MEMORY_BASE"
    local side="$1"
    git checkout --"$side" "$RESOLVE_FILE" 2>/dev/null || { echo "错误: 无法取 $side 版本: $RESOLVE_FILE"; exit 1; }
    git add "$RESOLVE_FILE"
    echo "✓ $RESOLVE_FILE 已取 $side 版本并 stage"
    echo "  继续: mcmPull --continue（或其他冲突文件）"
}

# ----------------------------------------------------------------------------
# --continue
# ----------------------------------------------------------------------------
cmd_continue() {
    cd "$MEMORY_BASE"
    # 仍有未解决冲突？
    if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        echo "✗ 仍有未解决冲突:"
        git diff --name-only --diff-filter=U | sed 's/^/    /'
        echo "  先用 mcmPull --ours|--theirs <file> 或手动编辑解决"
        exit 1
    fi
    _git_commit "mcm: merge resolved"
    echo "✓ 合并已提交"
    rebuild_derived
    emit_event "pull" resolved=true
}

# ----------------------------------------------------------------------------
# 默认: fetch + merge
# ----------------------------------------------------------------------------
cmd_pull() {
    cd "$MEMORY_BASE"

    [ -d .git ] || { echo "错误: $MEMORY_BASE 不是 git 仓库，先 mcmRemote init"; exit 1; }

    local remote="${REMOTE_NAME:-origin}"
    if ! git remote | grep -qx "$remote" 2>/dev/null; then
        echo "错误: remote '$remote' 不存在，先用 mcmRemote add"
        exit 1
    fi

    local branch
    branch=$(git branch --show-current 2>/dev/null || echo main)

    # 工作区脏检查（避免 merge 污染）——冲突解决后用 --continue 走另一路径
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo "✗ 工作区有未提交变更，先 mcmPush 或 stash："
        git status --short | sed 's/^/    /' | head -10
        echo "  （冲突解决中用 mcmPull --continue）"
        exit 1
    fi

    echo "• fetch $remote..."
    if ! git fetch "$remote" 2>/tmp/mcm_fetch.err; then
        echo "✗ fetch 失败:"
        sed 's/^/    /' /tmp/mcm_fetch.err 2>/dev/null || true
        exit 1
    fi

    # 无远程分支 -> 无可拉取
    if ! git rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
        echo "• 远程无 $branch 分支（首次推送前正常）"
        exit 0
    fi

    # 已是最新？
    if git merge-base --is-ancestor "$remote/$branch" HEAD 2>/dev/null; then
        echo "✓ 已是最新"
        exit 0
    fi

    echo "• merge $remote/$branch..."
    local rc=0
    git merge --no-edit "$remote/$branch" || rc=$?

    if [ "$rc" -ne 0 ]; then
        _report_conflicts
        emit_event "pull" conflict=true
        exit 1
    fi

    echo "✓ 合并完成"
    rebuild_derived
    emit_event "pull" remote="$remote"
}

main() {
    parse_args "$@"

    command -v git &>/dev/null || { echo "错误: 未找到 git"; exit 1; }

    local lock_token
    lock_token=$(acquire_lock "$GIT_LOCK")
    mcm_on_exit "release_lock '$GIT_LOCK' '$lock_token'"

    case "${ACTION:-pull}" in
        abort)    cmd_abort ;;
        ours)     cmd_resolve ours ;;
        theirs)   cmd_resolve theirs ;;
        continue) cmd_continue ;;
        pull)     cmd_pull ;;
    esac
}

mcm_run_command main "$@"

#!/bin/bash
# ============================================================================
# mcmRemote - git 远程记忆共享管理 (v4.0 Phase 7)
# ============================================================================
# Usage:
#   mcmRemote init [--remote <url>] [--device <name>]   git init + 配置 + 首次提交/推送
#   mcmRemote add <name> <url>                          添加 remote
#   mcmRemote list                                       列出 remote
#   mcmRemote remove <name>                             移除 remote
#   mcmRemote device [show | set <name>]                查看/设置本机 device id
# ============================================================================
# 设计见 docs/superpowers/specs/2026-07-09-git-remote-memory-sync-design.md
# 派生/机器本地态走 .gitignore；append-only 日志走 .gitattributes merge=union；
# L4 device registry 见 lib/core.sh record_l4_source。
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

SUBCMD=""
REMOTE_NAME=""
REMOTE_URL=""
DEVICE_NAME=""
DEVICE_ACTION="show"
GIT_LOCK="mcm-git"

usage() {
    cat <<EOF
用法: mcmRemote <子命令> [opts]
  init [--remote <url>] [--device <name>]   git init + .gitignore/.gitattributes + .device 盖戳 + 首次提交/推送
  add <name> <url>                            添加 remote（已存在则改 url）
  list                                         列出 remote
  remove <name>                               移除 remote
  device [show | set <name>]                  查看/设置本机 device id
EOF
    exit "${1:-0}"
}

parse_args() {
    SUBCMD="${1:-show}"
    [[ -z "$1" ]] && SUBCMD="usage"
    shift || true
    case "$SUBCMD" in
        init)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --remote) REMOTE_URL="$2"; shift 2 ;;
                    --device) DEVICE_NAME="$2"; shift 2 ;;
                    --help|-h) usage 0 ;;
                    *) echo "未知参数: $1"; usage 1 ;;
                esac
            done
            ;;
        add)
            [[ $# -ge 2 ]] || { echo "用法: mcmRemote add <name> <url>"; exit 1; }
            REMOTE_NAME="$1"; REMOTE_URL="$2"
            ;;
        remove)
            [[ $# -ge 1 ]] || { echo "用法: mcmRemote remove <name>"; exit 1; }
            REMOTE_NAME="$1"
            ;;
        device)
            DEVICE_ACTION="${1:-show}"
            if [[ "$DEVICE_ACTION" == "set" ]]; then
                [[ $# -ge 2 ]] || { echo "用法: mcmRemote device set <name>"; exit 1; }
                DEVICE_NAME="$2"
            fi
            ;;
        list) ;;
        --help|-h) usage 0 ;;
        usage) usage 0 ;;
        *) echo "未知子命令: $SUBCMD"; usage 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# .gitignore / .gitattributes（spec §3）
# ----------------------------------------------------------------------------
_write_gitignore() {
    cat > "$MEMORY_BASE/.gitignore" <<'GI'
# 派生文件(pull 后由 mcmSync/doctor 重建)
.search_index
index.md
**/hash.json

# 机器本地态
.locks/
.inject_state/
.inject_log
.trash/
.events.ndjson
.session_log.md
.device
.workspace

# .claude/ 下仅 l4/ device registry 同步,其余机器本地
.claude/*
!.claude/l4/
GI
}

_write_gitattributes() {
    cat > "$MEMORY_BASE/.gitattributes" <<'GA'
# append-only 日志: union 合并自动取两边,不打冲突标记
log.md      merge=union
ledger.md   merge=union

# 行尾统一,避免 CRLF 污染 frontmatter 解析(跨平台)
* text=auto eol=lf
GA
}

# git identity 容错：优先用全局/仓库已配置的，缺则用 mcm 默认
_git_commit() {
    local msg="$1"
    git commit -q -m "$msg" 2>/dev/null \
        || git -c user.name="mcm" -c user.email="mcm@local" commit -q -m "$msg"
}

# ----------------------------------------------------------------------------
# init: git init + 配置 + .device + 首次提交/推送
# ----------------------------------------------------------------------------
cmd_init() {
    command -v git &>/dev/null || { echo "错误: 未找到 git，请先安装"; exit 1; }
    mkdir -p "$MEMORY_BASE"

    local lock_token
    lock_token=$(acquire_lock "$GIT_LOCK")
    mcm_on_exit "release_lock '$GIT_LOCK' '$lock_token'"

    cd "$MEMORY_BASE"

    if [ ! -d .git ]; then
        git init -q
        echo "✓ git 仓库已初始化"
    else
        echo "• git 仓库已存在(跳过 init)"
    fi

    _write_gitignore
    _write_gitattributes
    echo "✓ .gitignore / .gitattributes 已写入"

    # device 盖戳（若 .device 不存在）
    if [ ! -f "$MEMORY_BASE/.device" ]; then
        local dev="${DEVICE_NAME:-$(hostname 2>/dev/null || echo unknown)}"
        printf '%s\n' "$dev" > "$MEMORY_BASE/.device"
        echo "✓ 本机 device id 已盖戳: $dev"
    else
        echo "• .device 已存在: $(cat "$MEMORY_BASE/.device")"
    fi

    # 首次提交
    git add -A
    if ! git diff --cached --quiet 2>/dev/null; then
        _git_commit "mcm: init remote store"
        echo "✓ 初始提交已创建"
    else
        echo "• 无变更需提交"
    fi

    # 规范分支名为 main
    git branch -m main 2>/dev/null || true

    # 可选 remote + push
    if [ -n "$REMOTE_URL" ]; then
        if git remote get-url origin &>/dev/null; then
            git remote set-url origin "$REMOTE_URL"
            echo "• origin url 已更新"
        else
            git remote add origin "$REMOTE_URL"
        fi
        echo "✓ origin -> $REMOTE_URL"
        local branch
        branch=$(git branch --show-current 2>/dev/null || echo main)
        if git push -u origin "$branch" 2>/tmp/mcm_push.err; then
            echo "✓ 已推送到 origin/$branch"
        else
            echo "⚠ push 失败(可能远程为空或需手动 push):"
            sed 's/^/  /' /tmp/mcm_push.err 2>/dev/null || true
        fi
    fi

    emit_event "remote.init" memory_base="$MEMORY_BASE"
}

# ----------------------------------------------------------------------------
# add / list / remove
# ----------------------------------------------------------------------------
cmd_add() {
    cd "$MEMORY_BASE"
    if git remote get-url "$REMOTE_NAME" &>/dev/null; then
        git remote set-url "$REMOTE_NAME" "$REMOTE_URL"
        echo "• remote url 已更新: $REMOTE_NAME -> $REMOTE_URL"
    else
        git remote add "$REMOTE_NAME" "$REMOTE_URL"
        echo "✓ remote 已添加: $REMOTE_NAME -> $REMOTE_URL"
    fi
    emit_event "remote.add" name="$REMOTE_NAME"
}

cmd_list() {
    cd "$MEMORY_BASE"
    if git remote | grep -q . 2>/dev/null; then
        git remote -v
    else
        echo "(无 remote，用 mcmRemote add <name> <url> 添加)"
    fi
}

cmd_remove() {
    cd "$MEMORY_BASE"
    git remote remove "$REMOTE_NAME"
    echo "✓ remote 已移除: $REMOTE_NAME"
    emit_event "remote.remove" name="$REMOTE_NAME"
}

# ----------------------------------------------------------------------------
# device show / set
# ----------------------------------------------------------------------------
cmd_device() {
    case "$DEVICE_ACTION" in
        show|"")
            local dev
            dev=$(current_device_id)
            echo "device id: $dev"
            if [ -n "${MCM_DEVICE:-}" ]; then
                echo "来源: MCM_DEVICE 环境变量"
            elif [ -f "$MEMORY_BASE/.device" ]; then
                echo "来源: .device 文件"
            else
                echo "来源: hostname(回退，建议 mcmRemote device set <name> 盖戳)"
            fi
            ;;
        set)
            printf '%s\n' "$DEVICE_NAME" > "$MEMORY_BASE/.device"
            echo "✓ device id 已设置: $DEVICE_NAME"
            emit_event "remote.device" device="$DEVICE_NAME"
            ;;
        *)
            echo "用法: mcmRemote device [show | set <name>]"; exit 1
            ;;
    esac
}

main() {
    parse_args "$@"
    case "$SUBCMD" in
        init)   cmd_init ;;
        add)    cmd_add ;;
        list)   cmd_list ;;
        remove) cmd_remove ;;
        device) cmd_device ;;
    esac
}

mcm_run_command main "$@"

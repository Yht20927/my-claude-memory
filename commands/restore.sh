#!/bin/bash
# ============================================================================
# mcmRestore - 从回收站恢复记忆 (v2.0)
# ============================================================================
# Usage: mcmRestore <回收站条目名> | mcmRestore --list
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

ENTRY=""
LIST_MODE=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)     LIST_MODE=true; shift ;;
            --help)     usage "用法: mcmRestore <回收站条目名> | mcmRestore --list" ;;
            *)          ENTRY="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ "$LIST_MODE" = true ]; then
        echo "## 回收站"
        echo ""
        list_trash
        exit 0
    fi

    if [ -z "$ENTRY" ]; then
        echo "用法: mcmRestore <回收站条目名> 或 mcmRestore --list"
        echo ""
        echo "回收站内容:"
        list_trash
        exit 1
    fi

    local lock_name="restore_${ENTRY}"
    local lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    # v3.2: 在 restore_from_trash 删除 .origin 前先取出原路径（旧代码在此之后才读
    # origin_file，而 restore_from_trash 内部已 rm 它 → 搜索索引更新被静默跳过；顺手修）
    local origin_file="$TRASH_DIR/.${ENTRY}.origin"
    local origin_path=""
    [ -f "$origin_file" ] && origin_path=$(cat "$origin_file")

    restore_from_trash "$ENTRY"

    # 增量更新搜索索引
    if [ -n "$origin_path" ]; then
        local is_global=false
        [[ "$origin_path" == *"/global/"* ]] && is_global=true
        local mem_name=$(basename "$origin_path")
        if [ -d "$origin_path" ]; then
            update_search_index "$mem_name" "$origin_path" "$is_global"
        fi
    fi

    # v3.2: op-log
    if [ -n "$origin_path" ] && [ -d "$origin_path" ]; then
        log_memory_op "$origin_path" "restore" "← trash:$ENTRY" "user"
    fi

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "恢复完成: $ENTRY"
}

mcm_run_command main "$@"

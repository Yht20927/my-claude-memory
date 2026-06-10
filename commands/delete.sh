#!/bin/bash
# ============================================================================
# mcmDelete - 删除记忆条目 (v2.0 — 移至回收站)
# ============================================================================
# Usage: mcmDelete <名称> [--force] [--global] [--dry-run]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

NAME=""
FORCE=false
IS_GLOBAL=false
DRY_RUN=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)    FORCE=true; shift ;;
            --global)   IS_GLOBAL=true; shift ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --help)     usage "用法: mcmDelete <名称> [--force] [--global] [--dry-run]" ;;
            *)          NAME="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Step 1: 确认删除
# ----------------------------------------------------------------------------

step1_confirm() {
    local memory_path="$1"

    if [ "$FORCE" = true ]; then
        return 0
    fi

    echo "确认删除记忆: $NAME"
    echo "  路径: $memory_path"
    echo "  将移至回收站 (可用 mcmRestore 恢复)"
    echo ""
    echo "输入 'yes' 确认删除："
    read -r confirm

    if [ "$confirm" = "yes" ]; then
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Step 2: 移至回收站
# ----------------------------------------------------------------------------

step2_delete() {
    local memory_path="$1"

    if [ ! -d "$memory_path" ]; then
        log "  目录不存在: $memory_path"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] 将移至回收站: $memory_path"
        return 0
    fi

    move_to_trash "$memory_path" "$NAME"
}

# ----------------------------------------------------------------------------
# Step 3: 更新索引
# ----------------------------------------------------------------------------

step3_update_index() {
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] 将从索引移除: $NAME"
        return
    fi

    if [ "$IS_GLOBAL" = true ]; then
        update_global_index "global" "" "$NAME" "" "remove"
    else
        update_global_index "project" "" "$NAME" "" "remove"
    fi
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$NAME" ]; then
        echo "用法: mcmDelete <名称> [--force] [--global] [--dry-run]"
        exit 1
    fi

    log "开始删除记忆: $NAME (global: $IS_GLOBAL)"
    [ "$DRY_RUN" = true ] && log "  DRY-RUN 模式 - 不会实际删除"

    local memory_path
    memory_path=$(find_memory_path "$NAME" "$IS_GLOBAL")

    if [ -z "$memory_path" ]; then
        log "未找到记忆: $NAME"
        exit 1
    fi

    local lock_name="delete_${NAME}"
    local lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    step1_confirm "$memory_path" || { log "取消删除"; exit 1; }
    step2_delete "$memory_path"
    step3_update_index

    # 从搜索索引中移除
    remove_from_search_index "$NAME" "$IS_GLOBAL"

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "已移至回收站: $NAME (使用 mcmRestore 恢复, mcmEmptyTrash 清空)"
}

mcm_run_command main "$@"

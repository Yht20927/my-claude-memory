#!/bin/bash
# ============================================================================
# mcmUpdate - 更新记忆元数据 (v2.0 — 支持标签变更)
# ============================================================================
# Usage: mcmUpdate <名称> [--name <新名>] [--description <描述>]
#                  [--tags <标签>] [--global]
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

NAME=""
NEW_NAME=""
NEW_DESCRIPTION=""
NEW_TAGS=""
IS_GLOBAL=false

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         NEW_NAME="$2"; shift 2 ;;
            --description)  NEW_DESCRIPTION="$2"; shift 2 ;;
            --tags)         NEW_TAGS="$2"; shift 2 ;;
            --global)       IS_GLOBAL=true; shift ;;
            --help)         usage "用法: mcmUpdate <名称> [--name <新名>] [--description <描述>] [--tags <标签>] [--global]" ;;
            *)              NAME="$1"; shift ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Step 1: 检测记忆
# ----------------------------------------------------------------------------

step1_detect() {
    local name="$1"
    local memory_path
    memory_path=$(find_memory_path "$name" "$IS_GLOBAL")

    if [ -z "$memory_path" ]; then
        echo ""
        return
    fi

    echo "$memory_path"
}

# ----------------------------------------------------------------------------
# Step 2: 更新 summary 和标签
# ----------------------------------------------------------------------------

step2_update() {
    local memory_path="$1"
    local current_path="$memory_path"

    # 交互模式
    if [ -z "$NEW_NAME" ] && [ -z "$NEW_DESCRIPTION" ] && [ -z "$NEW_TAGS" ] && [ -t 0 ]; then
        echo "请输入新名称（直接回车保持不变）:"
        read -r input_name
        [ -n "$input_name" ] && NEW_NAME="$input_name"

        echo "请输入新描述（直接回车保持不变）:"
        read -r input_desc
        [ -n "$input_desc" ] && NEW_DESCRIPTION="$input_desc"

        echo "请输入新标签（直接回车保持不变，逗号分隔多标签）:"
        read -r input_tags
        [ -n "$input_tags" ] && NEW_TAGS="$input_tags"
    fi

    local current_name=$(basename "$memory_path")

    # 标签变更: 移动目录到新标签分组
    if [ -n "$NEW_TAGS" ] && [ "$NEW_TAGS" != "$(get_current_tag "$memory_path")" ]; then
        # 取主标签作为物理目录分组（拒绝含逗号/特殊字符的整串）
        local default_tag="tools"
        [ "$IS_GLOBAL" = true ] && default_tag="auto"
        local primary_tag
        primary_tag=$(parse_primary_tag "$NEW_TAGS" "$default_tag")
        local parent_dir
        if [ "$IS_GLOBAL" = true ]; then
            parent_dir="$GLOBAL_DIR/$primary_tag"
        else
            parent_dir="$PROJECTS_DIR/$primary_tag"
        fi
        mkdir -p "$parent_dir"

        local target_name="${NEW_NAME:-$current_name}"
        local new_path="$parent_dir/$target_name"

        if [ "$current_path" != "$new_path" ]; then
            if [ -d "$new_path" ]; then
                log "  目标路径已存在: $new_path"
            else
                mv "$current_path" "$new_path"
                current_path="$new_path"
                log "  已移动到新标签分组: $primary_tag"
            fi
        fi
    fi

    # 重命名
    if [ -n "$NEW_NAME" ] && [ "$NEW_NAME" != "$(basename "$current_path")" ]; then
        local parent_dir=$(dirname "$current_path")
        local new_path="$parent_dir/$NEW_NAME"
        if mv "$current_path" "$new_path" 2>/dev/null; then
            current_path="$new_path"
            log "  目录已重命名: $NEW_NAME"
        else
            log "  重命名失败（目标已存在或无权限）: $NEW_NAME"
        fi
    fi

    # 更新 summary.md
    local final_name=$(basename "$current_path")
    if [ -n "$NEW_DESCRIPTION" ]; then
        cat > "$current_path/summary.md" <<EOF
# $final_name
$NEW_DESCRIPTION
EOF
    elif [ -n "$NEW_TAGS" ]; then
        # 仅追加标签到已有 summary（若未更新描述）
        local existing_desc=$(sed -n '2p' "$current_path/summary.md" 2>/dev/null || echo "")
        cat > "$current_path/summary.md" <<EOF
# $final_name
${existing_desc:-项目记忆: $final_name}
tags: $NEW_TAGS
EOF
    fi

    if [ -n "$NEW_DESCRIPTION" ] || [ -n "$NEW_TAGS" ]; then
        log "  summary.md 已更新"
    fi

    # 返回最终路径
    echo "$current_path"
}

# 获取记忆当前的 tag
get_current_tag() {
    local memory_path="$1"
    local parent=$(dirname "$memory_path")
    basename "$parent"
}

# ----------------------------------------------------------------------------
# Step 3: 同步全局索引
# ----------------------------------------------------------------------------

step3_sync_index() {
    local old_name="$1"
    local new_name="$2"
    local new_path="$3"

    if [ -n "$new_name" ] && [ "$new_name" != "$old_name" ]; then
        local index_file
        if [ "$IS_GLOBAL" = true ]; then
            index_file="$GLOBAL_DIR/index.md"
        else
            index_file="$PROJECTS_DIR/index.md"
        fi

        if [ -f "$index_file" ]; then
            local safe_old=$(sed_escape "$old_name")
            local safe_new=$(sed_escape "$new_name")
            sed_i "s/\[$safe_old\]/[$safe_new]/" "$index_file"
            log "  全局索引已同步"
        fi
    fi

    # 路径变更时更新索引中的 path
    if [ -n "$new_path" ]; then
        local index_file
        if [ "$IS_GLOBAL" = true ]; then
            index_file="$GLOBAL_DIR/index.md"
        else
            index_file="$PROJECTS_DIR/index.md"
        fi
        if [ -f "$index_file" ]; then
            local final_name="${new_name:-$old_name}"
            local tag=$(get_current_tag "$new_path")
            local safe_name=$(sed_escape "$final_name")
            if [ "$IS_GLOBAL" = true ]; then
                local rel_path="${new_path#$GLOBAL_DIR/}"
                sed_i "/\[$safe_name\]/s|path: .*|path: $rel_path/index.md|" "$index_file"
            else
                sed_i "/\[$safe_name\]/s|path: .*|path: $tag/$final_name/index.md|" "$index_file"
            fi
        fi
    fi
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -z "$NAME" ]; then
        echo "用法: mcmUpdate <名称> [--name <新名>] [--description <描述>] [--tags <标签>] [--global]"
        exit 1
    fi

    log "开始更新记忆: $NAME"

    local memory_path
    memory_path=$(step1_detect "$NAME")

    if [ -z "$memory_path" ]; then
        log "未找到记忆: $NAME"
        exit 1
    fi

    log "  路径: $memory_path"

    local lock_name="update_${NAME}"
    local lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    local new_path=$(step2_update "$memory_path")
    step3_sync_index "$NAME" "$NEW_NAME" "$new_path"

    # 更新搜索索引（目录可能已移动/重命名）
    local final_name="${NEW_NAME:-$NAME}"
    local is_global="$IS_GLOBAL"
    # 先移除旧名称的索引，再添加新路径的索引
    remove_from_search_index "$NAME" "$is_global"
    if [ -n "$new_path" ] && [ -d "$new_path" ]; then
        update_search_index "$final_name" "$new_path" "$is_global"
    fi

    # v3.2: op-log（写最终路径；new_path 可能为空=无变更）
    log_memory_op "${new_path:-$memory_path}" "update" "name=${NEW_NAME:-$NAME} desc=${NEW_DESCRIPTION:+set} tags=${NEW_TAGS:+set}" "user"

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers

    log "更新完成"
}

mcm_run_command main "$@"
